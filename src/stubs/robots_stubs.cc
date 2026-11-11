// OCaml adapter for Google's robots.txt parser and matcher
// (src/vendor/robotstxt, unmodified).
//
// googlebot::RobotsMatcher::AllowedByRobots re-tokenises the whole robots.txt
// on every call: line splitting, key recognition with typo tolerance, and a
// heap copy of every percent-escaped Allow/Disallow value. A crawler asks one
// robots.txt about many URLs, so this adapter parses it once and every URL
// check replays the parsed rules into an unmodified RobotsMatcher.
//
// The matcher's group bookkeeping (which user-agent lines name us, where a
// group ends) depends on the agent, never on the URL. So the recording pass
// keeps only the Allow/Disallow rules the matcher would evaluate for us,
// each with the group state in force on its line, and a replay sets that
// state before handing the rule to the matcher's own HandleAllow or
// HandleDisallow: priorities, the /index.htm rule and the final decision stay
// Google's code. src/bench/robots_bench.ml checks every decision against
// OneAgentAllowedByRobots on real robots.txt files.
//
// The same pass keeps every other directive (Sitemap, Crawl-delay,
// Content-Usage, License, ...) together with the group it sits in, for
// src/lib/robots.ml.
//
// For agent ContextBot and the start of the robots.txt that
// src/test/test_contextual.ml checks:
//   1  License: https://x.example/site.xml
//   2  User-agent: *
//   3  Disallow: /
//   4  Content-Usage: ai-use=n
//   5
//   6  User-agent: contextbot
//   7  Disallow: /private
//   8  Allow: /private/ok$
// the recording pass keeps rules 3 (global), 7 and 8 (specific), and
// directives license (line 1, kOutside) and content-usage (line 4,
// kGlobalGroup). Replays: /private/page disallowed by line 7, /private/ok
// allowed by line 8, /football/article allowed by no line (our group
// exists, so rule 3 of "*" does not apply).

#include <caml/alloc.h>
#include <caml/custom.h>
#include <caml/fail.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>

#include <cctype>
#include <string>
#include <vector>

#include "robots.h"

namespace googlebot {
// Defined with external linkage in robots.cc, not declared in robots.h.
std::string GetPathParamsQuery(const std::string& url);
bool MaybeEscapePattern(const char* src, char** dst);
}  // namespace googlebot

namespace {

// An Allow or Disallow rule in a group that applies to us.
struct Rule {
  bool allow;
  bool specific;  // seen_specific_agent_ on that line
  bool global;    // seen_global_agent_ on that line
  int line;
  std::string value;
};

// Where a directive sits when the parser reaches it. Must match
// Robots.scope_of in src/lib/robots.ml.
enum Scope : int { kOutside = 0, kGlobalGroup = 1, kOurGroup = 2, kOtherGroup = 3 };

struct Directive {
  std::string key;  // lower-cased
  std::string value;
  int line;
  int scope;
};

struct Compiled {
  std::vector<std::string> agents;
  std::vector<Rule> rules;
  std::vector<Directive> directives;
  bool our_group = false;
};

// RobotsMatcher with its protected callbacks and group state reachable.
class Matcher : public googlebot::RobotsMatcher {
 public:
  void Record(absl::string_view body, Compiled* out) {
    out_ = out;
    InitUserAgentsAndPath(&out->agents, "/");
    googlebot::ParseRobotsTxt(body, this);
    out->our_group = ever_seen_specific_agent();
    out_ = nullptr;
  }

  // The decision for one path, and the line that made it (0: none).
  bool Allowed(const Compiled& c, const char* path, int* line) {
    InitUserAgentsAndPath(&c.agents, path);
    HandleRobotsStart();
    ever_seen_specific_agent_ = c.our_group;
    for (const Rule& r : c.rules) {
      seen_specific_agent_ = r.specific;
      seen_global_agent_ = r.global;
      if (r.allow) {
        RobotsMatcher::HandleAllow(r.line, r.value);
      } else {
        RobotsMatcher::HandleDisallow(r.line, r.value);
      }
    }
    *line = matching_line();
    return !disallow();
  }

  // Whether an Allow-style pattern matches the path. RobotsMatchStrategy is
  // private to robots.cc, so the question goes through the matcher itself:
  // wildcards, '$' and escaping behave exactly as for Allow.
  bool PatternMatches(const char* path, absl::string_view pattern) {
    static const std::vector<std::string> anyone = {"x"};
    std::string raw(pattern);
    char* escaped = nullptr;
    const bool copied = googlebot::MaybeEscapePattern(raw.c_str(), &escaped);
    InitUserAgentsAndPath(&anyone, path);
    HandleRobotsStart();
    RobotsMatcher::HandleUserAgent(1, "*");
    RobotsMatcher::HandleAllow(2, escaped);
    if (copied) delete[] escaped;
    return matching_line() == 2;
  }

 protected:
  // While recording, the base class only has to track groups. Its allow and
  // disallow callbacks also match the path and, for /index.htm* patterns,
  // re-enter HandleAllow virtually; so they are not called, and the one piece
  // of group state they change, seen_separator_, is set here. A rule seen
  // while no group names us is skipped: the matcher returns at once on it.
  // Outside recording (that re-entry during a replay), the base runs.
  void HandleUserAgent(int line, absl::string_view value) override {
    RobotsMatcher::HandleUserAgent(line, value);
    if (out_ != nullptr) in_group_ = true;
  }
  void HandleAllow(int line, absl::string_view value) override {
    if (out_ == nullptr) return RobotsMatcher::HandleAllow(line, value);
    KeepRule(true, line, value);
  }
  void HandleDisallow(int line, absl::string_view value) override {
    if (out_ == nullptr) return RobotsMatcher::HandleDisallow(line, value);
    KeepRule(false, line, value);
  }
  void HandleSitemap(int line, absl::string_view value) override {
    if (out_ != nullptr) Keep("sitemap", line, value);
  }
  void HandleUnknownAction(int line, absl::string_view key,
                           absl::string_view value) override {
    if (out_ != nullptr) Keep(key, line, value);
  }

 private:
  void KeepRule(bool allow, int line, absl::string_view value) {
    if (!seen_any_agent()) return;
    seen_separator_ = true;
    out_->rules.push_back({allow, seen_specific_agent_, seen_global_agent_, line, std::string(value)});
  }

  void Keep(absl::string_view key, int line, absl::string_view value) {
    std::string k(key);
    for (char& ch : k) ch = static_cast<char>(std::tolower(static_cast<unsigned char>(ch)));
    const int scope = !in_group_             ? kOutside
                      : seen_specific_agent_ ? kOurGroup
                      : seen_global_agent_   ? kGlobalGroup
                                             : kOtherGroup;
    out_->directives.push_back({k, std::string(value), line, scope});
  }

  Compiled* out_ = nullptr;
  bool in_group_ = false;
};

// One matcher per OCaml domain (a domain is a thread); compiled robots.txt
// values are immutable and shared freely.
thread_local Matcher replayer;

struct Handle {
  Compiled* compiled;
};

Compiled* compiled_of(value v) {
  return reinterpret_cast<Handle*>(Data_custom_val(v))->compiled;
}

void finalize(value v) {
  Handle* h = reinterpret_cast<Handle*>(Data_custom_val(v));
  delete h->compiled;
  h->compiled = nullptr;
}

custom_operations operations = {
    "contextual.robots.v1",     finalize,
    custom_compare_default,     custom_hash_default,
    custom_serialize_default,   custom_deserialize_default,
    custom_compare_ext_default, custom_fixed_length_default,
};

std::string string_of(value v) { return {String_val(v), caml_string_length(v)}; }

}  // namespace

extern "C" value ctx_robots_compile(value v_body, value v_agent) {
  CAMLparam2(v_body, v_agent);
  CAMLlocal1(v);
  Compiled* c = nullptr;
  bool failed = false;
  try {
    c = new Compiled();
    c->agents.push_back(string_of(v_agent));
    Matcher m;
    m.Record({String_val(v_body), caml_string_length(v_body)}, c);
  } catch (...) {
    delete c;
    failed = true;
  }
  if (failed) caml_failwith("Robots.parse: native parser failed");
  v = caml_alloc_custom_mem(&operations, sizeof(Handle),
                            sizeof(Compiled) + caml_string_length(v_body));
  reinterpret_cast<Handle*>(Data_custom_val(v))->compiled = c;
  CAMLreturn(v);
}

// [@@noalloc]: (line lsl 1) lor allowed. Fails closed: an internal error
// reads as "disallowed, no line".
extern "C" value ctx_robots_decide(value v_compiled, value v_url) {
  try {
    const std::string path = googlebot::GetPathParamsQuery(string_of(v_url));
    int line = 0;
    const bool allowed = replayer.Allowed(*compiled_of(v_compiled), path.c_str(), &line);
    return Val_long((static_cast<intnat>(line) << 1) | (allowed ? 1 : 0));
  } catch (...) {
    return Val_long(0);
  }
}

// [@@noalloc]
extern "C" value ctx_robots_our_group(value v_compiled) {
  return Val_bool(compiled_of(v_compiled)->our_group);
}

// [@@noalloc]. Fails closed: an internal error reads as "no match".
extern "C" value ctx_robots_pattern_matches(value v_url, value v_pattern) {
  try {
    const std::string path = googlebot::GetPathParamsQuery(string_of(v_url));
    return Val_bool(replayer.PatternMatches(path.c_str(), string_of(v_pattern)));
  } catch (...) {
    return Val_false;
  }
}

// (key, value, line, scope) array, in file order.
extern "C" value ctx_robots_directives(value v_compiled) {
  CAMLparam1(v_compiled);
  CAMLlocal3(v_array, v_tuple, v_string);
  const Compiled* c = compiled_of(v_compiled);
  v_array = caml_alloc(c->directives.size(), 0);
  for (size_t i = 0; i < c->directives.size(); ++i) {
    const Directive& d = c->directives[i];
    v_tuple = caml_alloc_tuple(4);
    v_string = caml_alloc_initialized_string(d.key.size(), d.key.data());
    Store_field(v_tuple, 0, v_string);
    v_string = caml_alloc_initialized_string(d.value.size(), d.value.data());
    Store_field(v_tuple, 1, v_string);
    Store_field(v_tuple, 2, Val_int(d.line));
    Store_field(v_tuple, 3, Val_int(d.scope));
    Store_field(v_array, i, v_tuple);
  }
  CAMLreturn(v_array);
}
