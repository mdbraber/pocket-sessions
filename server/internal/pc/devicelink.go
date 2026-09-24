package pc

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"time"
)

// The device-code link — how the server gets its own PC token lineage without a
// password ever being involved. It is PC's production TV-pairing flow:
//
//  1. POST /device/authorize (scope "tv" — the only scope PC accepts here)
//     → device_code + user_code + verification URL.
//  2. Someone with a session on the account approves the user_code: the app via
//     its authenticated POST /device/approve, or a browser at pocketcasts.com/pair.
//  3. POST /user/token with the device_code grant → an access token AND a rotating
//     refresh token: an independent lineage that outlives the app's own logins.
//
// Verified 2026-07-28 against the production API: the tv-scoped token reads
// /up_next/sync + /history/sync and passes write auth, and redeeming does not
// disturb any existing session.

// DeviceScope is the only scope PC's /device/authorize accepts.
const DeviceScope = "tv"

// ErrAuthorizationPending — the user hasn't approved the code yet; poll again.
var ErrAuthorizationPending = errors.New("authorization pending")

type DeviceAuthorization struct {
	DeviceCode              string
	UserCode                string
	VerificationURI         string
	VerificationURIComplete string
	ExpiresIn               int // seconds the codes stay valid
	Interval                int // suggested polling interval, seconds
}

// DeviceAuthorize starts the flow. Wire (from the app's api.pb.swift):
// DeviceAuthorizeRequest{1:scope}; DeviceAuthorizeResponse{1:device_code,
// 2:user_code, 3:verification_uri, 4:verification_uri_complete, 5:expires_in,
// 6:interval}.
func DeviceAuthorize(ctx context.Context) (DeviceAuthorization, error) {
	body := appendStringField(nil, 1, DeviceScope)
	data, err := postProto(ctx, "/device/authorize", body, "")
	if err != nil {
		return DeviceAuthorization{}, err
	}
	fields, err := parseAllFields(data)
	if err != nil {
		return DeviceAuthorization{}, fmt.Errorf("device authorize: bad response: %w", err)
	}
	out := DeviceAuthorization{
		DeviceCode:              string(fields.bytes[1]),
		UserCode:                string(fields.bytes[2]),
		VerificationURI:         string(fields.bytes[3]),
		VerificationURIComplete: string(fields.bytes[4]),
		ExpiresIn:               int(fields.varints[5]),
		Interval:                int(fields.varints[6]),
	}
	if out.DeviceCode == "" || out.UserCode == "" {
		return DeviceAuthorization{}, fmt.Errorf("device authorize: empty codes in response")
	}
	return out, nil
}

// RedeemDeviceCode polls the token endpoint for an approved device code.
// Returns ErrAuthorizationPending until the code is approved. Wire:
// UserTokenRequest{2:grant_type, 4:scope, 5:device_code} → TokenLoginResponse.
func RedeemDeviceCode(ctx context.Context, deviceCode string) (TokenExchange, error) {
	body := appendStringField(nil, 2, "urn:ietf:params:oauth:grant-type:device_code")
	body = appendStringField(body, 4, DeviceScope)
	body = appendStringField(body, 5, deviceCode)
	data, err := postProto(ctx, "/user/token", body, "")
	if err != nil {
		return TokenExchange{}, err
	}
	return parseTokenLoginResponse(data)
}

// PasswordLogin is the operator fallback: one POST /user/login. PC's password
// login returns ONLY an access token (no refresh token — verified against the
// checked-in proto and the app's behavior), so links made this way expire and
// need re-linking; the device flow above is the primary path. The password is
// used for this single request and never stored.
// Wire: UserLoginRequest{1:email, 2:password, 3:scope} →
// UserLoginResponse{1:token, 2:uuid, 3:email}.
func PasswordLogin(ctx context.Context, email, password string) (TokenExchange, error) {
	body := appendStringField(nil, 1, email)
	body = appendStringField(body, 2, password)
	body = appendStringField(body, 3, "mobile")
	data, err := postProto(ctx, "/user/login", body, "")
	if err != nil {
		return TokenExchange{}, err
	}
	fields, err := parseLenDelimited(data)
	if err != nil {
		return TokenExchange{}, fmt.Errorf("pc login: bad response: %w", err)
	}
	out := TokenExchange{
		AccessToken: string(fields[1]),
		Email:       string(fields[3]),
	}
	if out.AccessToken == "" {
		return TokenExchange{}, fmt.Errorf("pc login: empty access token")
	}
	return out, nil
}

// postProto posts a protobuf body and returns the response bytes. Non-200
// responses carry a JSON error document; "authorization_pending" maps to
// ErrAuthorizationPending so device-code pollers can tell "not yet" from "no".
func postProto(ctx context.Context, path string, body []byte, accessToken string) ([]byte, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, apiBase+path, bytesReader(body))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/octet-stream")
	req.Header.Set("Accept", "application/octet-stream")
	req.Header.Set("User-Agent", "Pocket Casts")
	if accessToken != "" {
		req.Header.Set("Authorization", "Bearer "+accessToken)
	}

	client := &http.Client{Timeout: 20 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return nil, err
	}
	if resp.StatusCode != http.StatusOK {
		var apiErr struct {
			Error            string `json:"error"`
			ErrorDescription string `json:"error_description"`
			ErrorMessage     string `json:"errorMessage"`
		}
		if json.Unmarshal(data, &apiErr) == nil {
			if apiErr.Error == "authorization_pending" {
				return nil, ErrAuthorizationPending
			}
			if msg := apiErr.ErrorDescription + apiErr.ErrorMessage; msg != "" {
				return nil, fmt.Errorf("pc %s: HTTP %d: %s", path, resp.StatusCode, msg)
			}
		}
		return nil, fmt.Errorf("pc %s: HTTP %d", path, resp.StatusCode)
	}
	return data, nil
}

// parseTokenLoginResponse decodes TokenLoginResponse{1:email, 2:uuid, 4:access_token,
// 7:refresh_token}.
func parseTokenLoginResponse(data []byte) (TokenExchange, error) {
	fields, err := parseLenDelimited(data)
	if err != nil {
		return TokenExchange{}, fmt.Errorf("pc token response: %w", err)
	}
	out := TokenExchange{
		Email:        string(fields[1]),
		AccessToken:  string(fields[4]),
		RefreshToken: string(fields[7]),
	}
	if out.AccessToken == "" {
		return TokenExchange{}, fmt.Errorf("pc token response: empty access token")
	}
	return out, nil
}
