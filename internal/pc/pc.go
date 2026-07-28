// Package pc talks to Pocket Casts as "just another client device". M2 stage 1:
// the token exchange — the app hands us its refresh token once (never a password),
// and we mint access tokens the same way the app does.
//
// The messages involved are tiny, so the protobuf wire format is hand-rolled here
// rather than dragging in protoc: field numbers come from the app's checked-in
// api.pb.swift (UserTokenRequest: 2=grantType, 3=refreshToken, 4=scope;
// TokenLoginResponse: 1=email, 4=accessToken, 7=refreshToken).
package pc

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"time"
)

const apiBase = "https://api.pocketcasts.com"

type TokenExchange struct {
	Email        string
	AccessToken  string
	RefreshToken string // PC rotates refresh tokens — persist this one, not the input
}

// ExchangeRefreshToken redeems a PC refresh token for a fresh access token,
// exactly like the app's TokenHelper does against POST /user/token.
func ExchangeRefreshToken(ctx context.Context, refreshToken string) (TokenExchange, error) {
	body := appendStringField(nil, 2, "refresh_token")
	body = appendStringField(body, 3, refreshToken)
	body = appendStringField(body, 4, "mobile")

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, apiBase+"/user/token", bytesReader(body))
	if err != nil {
		return TokenExchange{}, err
	}
	req.Header.Set("Content-Type", "application/octet-stream")
	req.Header.Set("Accept", "application/octet-stream")
	req.Header.Set("User-Agent", "Pocket Casts")

	client := &http.Client{Timeout: 15 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return TokenExchange{}, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return TokenExchange{}, fmt.Errorf("pc token exchange: HTTP %d", resp.StatusCode)
	}
	data, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return TokenExchange{}, err
	}

	fields, err := parseLenDelimited(data)
	if err != nil {
		return TokenExchange{}, fmt.Errorf("pc token exchange: bad response: %w", err)
	}
	out := TokenExchange{
		Email:        string(fields[1]),
		AccessToken:  string(fields[4]),
		RefreshToken: string(fields[7]),
	}
	if out.AccessToken == "" {
		return TokenExchange{}, fmt.Errorf("pc token exchange: empty access token")
	}
	return out, nil
}

// --- minimal proto3 wire helpers ---

func appendVarint(b []byte, v uint64) []byte {
	for v >= 0x80 {
		b = append(b, byte(v)|0x80)
		v >>= 7
	}
	return append(b, byte(v))
}

func appendStringField(b []byte, field int, s string) []byte {
	if s == "" {
		return b
	}
	b = appendVarint(b, uint64(field)<<3|2)
	b = appendVarint(b, uint64(len(s)))
	return append(b, s...)
}

// parseLenDelimited walks a message and returns the last value of every
// length-delimited field (strings/messages); varint and fixed fields are skipped.
func parseLenDelimited(data []byte) (map[int][]byte, error) {
	out := map[int][]byte{}
	i := 0
	readVarint := func() (uint64, error) {
		var v uint64
		var shift uint
		for {
			if i >= len(data) {
				return 0, fmt.Errorf("truncated varint")
			}
			b := data[i]
			i++
			v |= uint64(b&0x7F) << shift
			if b < 0x80 {
				return v, nil
			}
			shift += 7
			if shift > 63 {
				return 0, fmt.Errorf("varint overflow")
			}
		}
	}
	for i < len(data) {
		key, err := readVarint()
		if err != nil {
			return nil, err
		}
		field, wire := int(key>>3), int(key&7)
		switch wire {
		case 0: // varint
			if _, err := readVarint(); err != nil {
				return nil, err
			}
		case 1: // fixed64
			if i+8 > len(data) {
				return nil, fmt.Errorf("truncated fixed64")
			}
			i += 8
		case 2: // length-delimited
			length, err := readVarint()
			if err != nil {
				return nil, err
			}
			if uint64(len(data)-i) < length {
				return nil, fmt.Errorf("truncated bytes field")
			}
			out[field] = data[i : i+int(length)]
			i += int(length)
		case 5: // fixed32
			if i+4 > len(data) {
				return nil, fmt.Errorf("truncated fixed32")
			}
			i += 4
		default:
			return nil, fmt.Errorf("unsupported wire type %d", wire)
		}
	}
	return out, nil
}

func bytesReader(b []byte) io.Reader { return &sliceReader{b: b} }

type sliceReader struct{ b []byte }

func (r *sliceReader) Read(p []byte) (int, error) {
	if len(r.b) == 0 {
		return 0, io.EOF
	}
	n := copy(p, r.b)
	r.b = r.b[n:]
	return n, nil
}

// ValidateAccessToken proves a PC access token still works, for links made without a
// refresh token. Any authenticated endpoint would do; subscription/status is cheap.
func ValidateAccessToken(ctx context.Context, accessToken string) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, apiBase+"/subscription/status", nil)
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+accessToken)
	req.Header.Set("Accept", "application/octet-stream")
	req.Header.Set("User-Agent", "Pocket Casts")

	client := &http.Client{Timeout: 15 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusUnauthorized || resp.StatusCode == http.StatusForbidden {
		return fmt.Errorf("pc rejected access token: HTTP %d", resp.StatusCode)
	}
	if resp.StatusCode >= 500 {
		return fmt.Errorf("pc unavailable: HTTP %d", resp.StatusCode)
	}
	return nil
}

func appendVarintField(b []byte, field int, v uint64) []byte {
	b = appendVarint(b, uint64(field)<<3)
	return appendVarint(b, v)
}

// parsedFields keeps every wire shape a caller might need: varints, the last
// value per length-delimited field, and all repeated length-delimited values.
type parsedFields struct {
	varints  map[int]uint64
	bytes    map[int][]byte
	repeated map[int][][]byte
}

func parseAllFields(data []byte) (parsedFields, error) {
	out := parsedFields{varints: map[int]uint64{}, bytes: map[int][]byte{}, repeated: map[int][][]byte{}}
	i := 0
	readVarint := func() (uint64, error) {
		var v uint64
		var shift uint
		for {
			if i >= len(data) {
				return 0, fmt.Errorf("truncated varint")
			}
			b := data[i]
			i++
			v |= uint64(b&0x7F) << shift
			if b < 0x80 {
				return v, nil
			}
			shift += 7
			if shift > 63 {
				return 0, fmt.Errorf("varint overflow")
			}
		}
	}
	for i < len(data) {
		key, err := readVarint()
		if err != nil {
			return out, err
		}
		field, wire := int(key>>3), int(key&7)
		switch wire {
		case 0:
			v, err := readVarint()
			if err != nil {
				return out, err
			}
			out.varints[field] = v
		case 1:
			if i+8 > len(data) {
				return out, fmt.Errorf("truncated fixed64")
			}
			i += 8
		case 2:
			length, err := readVarint()
			if err != nil {
				return out, err
			}
			if uint64(len(data)-i) < length {
				return out, fmt.Errorf("truncated bytes field")
			}
			val := data[i : i+int(length)]
			out.bytes[field] = val
			out.repeated[field] = append(out.repeated[field], val)
			i += int(length)
		case 5:
			if i+4 > len(data) {
				return out, fmt.Errorf("truncated fixed32")
			}
			i += 4
		default:
			return out, fmt.Errorf("unsupported wire type %d", wire)
		}
	}
	return out, nil
}

func appendBytesField(b []byte, field int, val []byte) []byte {
	if len(val) == 0 {
		return b
	}
	b = appendVarint(b, uint64(field)<<3|2)
	b = appendVarint(b, uint64(len(val)))
	return append(b, val...)
}
