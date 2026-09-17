package makai

import (
	"crypto/rand"
	"sync"
	"time"
)

// Protocol id formats, per the V1 spec section 3.1. Both are opaque to
// callers; the SDK generates them and the runtime echoes them back.
const (
	ulidLength   = 26
	nanoIDLength = 21
)

// crockford is Crockford's Base32 alphabet: the digits plus the uppercase
// letters with I, L, O and U removed.
const crockford = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

// nanoAlphabet matches the alphabet the TypeScript SDK uses for session ids,
// which the runtime validates as [A-Za-z0-9]{21}.
const nanoAlphabet = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"

var ulidState struct {
	sync.Mutex
	lastMillis int64
	lastRandom [10]byte
}

// newULID returns a 26-character uppercase Crockford Base32 ULID, used for
// message_id, stream_id and flow_id fields.
//
// ULIDs generated within the same millisecond increase monotonically: the
// 80-bit random component is incremented rather than redrawn, so a burst of
// ids sorts in generation order. On overflow (which needs 2^80 ids inside one
// millisecond) the component is redrawn.
func newULID() string {
	now := time.Now().UnixMilli()

	ulidState.Lock()
	if now != ulidState.lastMillis || !incrementRandom(&ulidState.lastRandom) {
		ulidState.lastMillis = now
		randomBytes(ulidState.lastRandom[:])
	}
	entropy := ulidState.lastRandom
	millis := ulidState.lastMillis
	ulidState.Unlock()

	out := make([]byte, ulidLength)
	// Timestamp: 48 bits, encoded least-significant character last across 10
	// Base32 characters. The 10 characters hold 50 bits, so the top two bits
	// are always zero.
	ts := uint64(millis) & 0xFFFFFFFFFFFF
	for i := 9; i >= 0; i-- {
		out[i] = crockford[ts&0x1F]
		ts >>= 5
	}
	// Randomness: 80 bits as exactly 16 Base32 characters.
	encodeBase32(out[10:], entropy[:])
	return string(out)
}

// encodeBase32 writes len(src)*8/5 Crockford Base32 characters into dst,
// consuming src most-significant bit first. len(src)*8 must be a multiple
// of 5.
func encodeBase32(dst, src []byte) {
	bit := 0
	for i := range dst {
		v := byte(0)
		for k := 0; k < 5; k++ {
			v = v<<1 | ((src[bit>>3] >> (7 - uint(bit&7))) & 1)
			bit++
		}
		dst[i] = crockford[v]
	}
}

// incrementRandom adds one to the big-endian 80-bit value in place and
// reports whether it did so without overflowing.
func incrementRandom(b *[10]byte) bool {
	for i := len(b) - 1; i >= 0; i-- {
		b[i]++
		if b[i] != 0 {
			return true
		}
	}
	return false
}

// newNanoID returns a 21-character alphanumeric NanoID, used for agent
// session ids.
func newNanoID() string {
	out := make([]byte, nanoIDLength)
	// 62 does not divide 256 evenly; reject the top byte values so every
	// alphabet position stays equally likely.
	const limit = byte(256 - (256 % len(nanoAlphabet)))
	buf := make([]byte, nanoIDLength*2)
	filled := 0
	for filled < nanoIDLength {
		randomBytes(buf)
		for _, b := range buf {
			if b >= limit {
				continue
			}
			out[filled] = nanoAlphabet[int(b)%len(nanoAlphabet)]
			filled++
			if filled == nanoIDLength {
				break
			}
		}
	}
	return string(out)
}

// isNanoID reports whether value has the 21-character alphanumeric shape the
// agent protocol requires for a session id.
func isNanoID(value string) bool {
	if len(value) != nanoIDLength {
		return false
	}
	for i := 0; i < len(value); i++ {
		c := value[i]
		switch {
		case c >= '0' && c <= '9':
		case c >= 'A' && c <= 'Z':
		case c >= 'a' && c <= 'z':
		default:
			return false
		}
	}
	return true
}

// randomBytes fills b with cryptographically secure randomness.
//
// crypto/rand.Read does not fail on any supported platform. Should it ever
// return an error, the fallback keeps ids unique within the process (the ULID
// timestamp and its monotonic increment still advance) rather than panicking
// in library code.
func randomBytes(b []byte) {
	if _, err := rand.Read(b); err != nil {
		now := uint64(time.Now().UnixNano())
		for i := range b {
			now = now*6364136223846793005 + 1442695040888963407
			b[i] = byte(now >> 32)
		}
	}
}
