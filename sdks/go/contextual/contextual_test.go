package contextual

import (
	"bufio"
	"context"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"os"
	"strconv"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"google.golang.org/protobuf/encoding/protowire"
)

// tsv reads a fixture written by the OCaml side (src/sdkfixtures).
func tsv(t testing.TB, name string) [][]string {
	t.Helper()
	f, err := os.Open("testdata/" + name) //nolint:gosec // fixture names are constants
	require.NoError(t, err)
	t.Cleanup(func() { _ = f.Close() })
	var rows [][]string
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 1<<16), 1<<20)
	for sc.Scan() {
		rows = append(rows, strings.Split(sc.Text(), "\t"))
	}
	require.NoError(t, sc.Err())

	return rows
}

func ids(csv string) []CategoryID {
	if csv == "" {
		return nil
	}
	var out []CategoryID
	for _, id := range strings.Split(csv, ",") {
		out = append(out, CategoryID(id))
	}

	return out
}

func TestKeyMatchesTheOCamlWriter(t *testing.T) {
	rows := tsv(t, "keys.tsv")
	require.NotEmpty(t, rows)
	for _, row := range rows {
		assert.Equal(t, row[1], Key(row[0]), "normalised URL %q", row[0])
		section, site := Sections(row[0])
		assert.Equal(t, row[2], keyOrEmpty(section), "section of %q", row[0])
		assert.Equal(t, row[3], keyOrEmpty(site), "site of %q", row[0])
	}
}

func keyOrEmpty(prefix string) string {
	if prefix == "" {
		return ""
	}

	return SectionKey(prefix)
}

func TestCheckMatchesTheOCamlMatcher(t *testing.T) {
	want := map[string]Verdict{"eligible": Eligible, "block": Blocked, "sensitive": Unsuitable, "target": OffTarget}
	rows := tsv(t, "refusal.tsv")
	require.Len(t, rows, 3000)
	var p Profile
	for i, row := range rows {
		b, err := hex.DecodeString(row[0])
		require.NoError(t, err)
		require.NoError(t, p.Decode(b))
		rule := Rule{Targets: ids(row[1]), Blocks: ids(row[2]), AvoidSensitive: row[3] == "1"}
		assert.Equal(t, want[row[4]], rule.Check(&p).Verdict, "case %d: %v", i+1, row[1:])
	}
}

func profileBytes(labels ...Label) []byte {
	var b []byte
	for _, l := range labels {
		var lb []byte
		lb = protowire.AppendTag(lb, 1, protowire.BytesType)
		lb = protowire.AppendString(lb, string(l.ID))
		lb = protowire.AppendTag(lb, 2, protowire.Fixed32Type)
		lb = protowire.AppendFixed32(lb, math.Float32bits(l.Score))
		b = protowire.AppendTag(b, 1, protowire.BytesType)
		b = protowire.AppendBytes(b, lb)
	}
	b = protowire.AppendTag(b, 3, protowire.VarintType)

	return protowire.AppendVarint(b, 1793873484)
}

func TestDecode(t *testing.T) {
	var p Profile
	b := profileBytes(Label{"483", 0.9}, Label{"533", 0.8})
	// A field a later writer may add is skipped.
	b = protowire.AppendTag(b, 9, protowire.BytesType)
	b = protowire.AppendString(b, "future")
	require.NoError(t, p.Decode(b))
	assert.Equal(t, []Label{{"483", 0.9}, {"533", 0.8}}, p.Labels)
	assert.Equal(t, int64(1793873484), p.FetchedAt)
	assert.InDelta(t, 0.8, p.Score("533"), 1e-6)
	assert.Zero(t, p.Score("1"))

	require.NoError(t, p.Decode(nil))
	assert.Empty(t, p.Labels)
	assert.Error(t, p.Decode([]byte{0x0a, 0x05, 0x0a}))
}

func TestMinScore(t *testing.T) {
	var p Profile
	require.NoError(t, p.Decode(profileBytes(Label{"483", 0.6})))
	sports := Rule{Targets: []CategoryID{"483"}}
	assert.Equal(t, Decision{Eligible, Label{"483", 0.6}}, sports.Check(&p))
	sports.MinScore = 0.7
	assert.Equal(t, Decision{Verdict: OffTarget}, sports.Check(&p))
}

type fakeCache map[string][]byte

func (c fakeCache) Get(_ context.Context, key string) ([]byte, bool, error) {
	if key == Key("broken.example/x") {
		return nil, false, errors.New("timeout")
	}
	v, ok := c[key]

	return v, ok, nil
}

func TestReader(t *testing.T) {
	r := NewReader(fakeCache{Key("news.example/sport/derby"): profileBytes(Label{"483", 0.9})})
	var p Profile
	found, err := r.Lookup(context.Background(), "news.example/sport/derby", &p)
	require.NoError(t, err)
	assert.True(t, found)
	assert.InDelta(t, 0.9, p.Score("483"), 1e-6)

	found, err = r.Lookup(context.Background(), "news.example/never-crawled", &p)
	require.NoError(t, err)
	assert.False(t, found)

	_, err = r.Lookup(context.Background(), "broken.example/x", &p)
	assert.ErrorContains(t, err, "timeout")
}

func TestLookupWithBackoff(t *testing.T) {
	r := NewReader(fakeCache{
		Key("news.example/sport/derby"):  profileBytes(Label{"483", 0.9}),
		SectionKey("news.example/sport"): profileBytes(Label{"483", 0.7}),
		SectionKey("news.example"):       profileBytes(Label{"379", 0.4}),
	})
	var p Profile
	for _, c := range []struct {
		url   string
		level Level
		id    CategoryID
	}{
		{"news.example/sport/derby", Page, "483"},
		{"news.example/sport/2026/11/10/new-signing?id=1", Section, "483"},
		{"news.example/politics/vote", Site, "379"},
		{"news.example", Site, "379"},
		{"other.example/sport/derby", NotFound, ""},
	} {
		level, err := r.LookupWithBackoff(context.Background(), c.url, &p)
		require.NoError(t, err)
		assert.Equal(t, c.level, level, c.url)
		if c.id != "" {
			assert.Positive(t, p.Score(c.id), c.url)
		}
	}
	_, err := r.LookupWithBackoff(context.Background(), "broken.example/x", &p)
	assert.ErrorContains(t, err, "timeout")
}

func TestSensitiveMatchesTheTaxonomy(t *testing.T) {
	rows := tsv(t, "sensitive.txt")
	require.Len(t, rows, len(sensitive))
	for _, row := range rows {
		assert.True(t, sensitive[CategoryID(row[0])], row[0])
	}
}

func TestAtSlotMatchesTheOCamlSlot(t *testing.T) {
	rows := tsv(t, "context.tsv")
	require.Len(t, rows, 2000)
	var p, out Profile
	var slot Slot
	for i, row := range rows {
		raw, err := hex.DecodeString(row[0])
		require.NoError(t, err)
		require.NoError(t, p.Decode(raw), "row %d", i)
		require.NoError(t, json.Unmarshal([]byte(row[2]), &slot), "row %d", i)
		p.AtSlot(&slot, row[1], &out)
		want := map[string]float64{}
		if row[3] != "" {
			for _, kv := range strings.Split(row[3], ";") {
				k, v, _ := strings.Cut(kv, "=")
				f, err := strconv.ParseFloat(v, 64)
				require.NoError(t, err)
				want[k] = f
			}
		}
		require.Len(t, out.Labels, len(want), "row %d: %v vs %s", i, out.Labels, row[3])
		for _, l := range out.Labels {
			w, ok := want[string(l.ID)]
			require.True(t, ok, "row %d: unexpected %s", i, l.ID)
			assert.InDelta(t, w, float64(l.Score), 1e-5, "row %d %s", i, l.ID)
		}
	}
}

func TestSlotOfGPIDMatchesTheOCamlProfile(t *testing.T) {
	rows := tsv(t, "gpid.tsv")
	require.Len(t, rows, 1000)
	var p Profile
	var s Slot
	for i, row := range rows {
		raw, err := hex.DecodeString(row[0])
		require.NoError(t, err)
		require.NoError(t, p.Decode(raw))
		ok := p.SlotOfGPID(row[1], &s)
		if row[2] == "none" {
			assert.False(t, ok, "row %d", i)
			continue
		}
		require.True(t, ok, "row %d", i)
		var want []string
		if row[2] != "" {
			want = strings.Split(row[2], ";")
		}
		require.Len(t, s.Blocks, len(want), "row %d", i)
		for j, w := range want {
			h, d, _ := strings.Cut(w, ":")
			f, err := strconv.ParseFloat(d, 64)
			require.NoError(t, err)
			assert.Equal(t, h, fmt.Sprintf("%016x", s.Blocks[j].SimHash), "row %d block %d", i, j)
			assert.InDelta(t, f, s.Blocks[j].Offset, 1e-6, "row %d block %d", i, j)
		}
	}
}

func TestBlocksDecodeWithoutAllocating(t *testing.T) {
	raw, err := hex.DecodeString(tsv(t, "context.tsv")[3][0])
	require.NoError(t, err)
	var p Profile
	require.NoError(t, p.Decode(raw))
	allocs := testing.AllocsPerRun(1000, func() { _ = p.Decode(raw) })
	assert.Zero(t, allocs)
}

func TestHitPathDoesNotAllocate(t *testing.T) {
	b := profileBytes(Label{"483", 0.9}, Label{"533", 0.8}, Label{SensitiveTopics, 0.2})
	rule := Rule{Targets: []CategoryID{"533"}, Blocks: []CategoryID{"52"}, AvoidSensitive: true}
	var p Profile
	require.NoError(t, p.Decode(b))
	allocs := testing.AllocsPerRun(1000, func() {
		_ = p.Decode(b)
		_ = rule.Check(&p)
	})
	assert.Zero(t, allocs)
}

func benchProfile(b *testing.B) ([]byte, Rule) {
	b.Helper()
	rows := tsv(b, "refusal.tsv")
	raw, err := hex.DecodeString(rows[0][0])
	require.NoError(b, err)

	return raw, Rule{Targets: ids(rows[0][1]), Blocks: ids(rows[0][2]), AvoidSensitive: rows[0][3] == "1"}
}

func BenchmarkDecode(b *testing.B) {
	raw, _ := benchProfile(b)
	var p Profile
	b.ReportAllocs()
	for b.Loop() {
		_ = p.Decode(raw)
	}
}

func BenchmarkCheck(b *testing.B) {
	raw, rule := benchProfile(b)
	var p Profile
	require.NoError(b, p.Decode(raw))
	b.ReportAllocs()
	for b.Loop() {
		_ = rule.Check(&p)
	}
}

func BenchmarkKey(b *testing.B) {
	b.ReportAllocs()
	for b.Loop() {
		_ = Key("lefigaro.fr/economie/la-dette-de-l-etat-2026")
	}
}

func BenchmarkAtSlot(b *testing.B) {
	var rows [][]string
	for _, row := range tsv(b, "context.tsv") {
		if strings.Count(row[2], "[") >= 6 { // a profile and a request with several blocks
			rows = append(rows, row)
		}
	}
	require.NotEmpty(b, rows)
	raw, err := hex.DecodeString(rows[0][0])
	require.NoError(b, err)
	var p, out Profile
	var slot Slot
	require.NoError(b, p.Decode(raw))
	require.NoError(b, json.Unmarshal([]byte(rows[0][2]), &slot))
	b.ReportAllocs()
	for b.Loop() {
		p.AtSlot(&slot, rows[0][1], &out)
	}
}
