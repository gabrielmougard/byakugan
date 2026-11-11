// Google's matcher called the way apeschar/robotstxt-ocaml calls it: the
// robots.txt is parsed again for every URL. Benchmark baseline only.

#include <caml/mlvalues.h>

#include <string>

#include "robots.h"

extern "C" value bench_robots_oneshot(value v_body, value v_agent, value v_url) {
  thread_local googlebot::RobotsMatcher matcher;
  return Val_bool(matcher.OneAgentAllowedByRobots(
      {String_val(v_body), caml_string_length(v_body)},
      std::string(String_val(v_agent), caml_string_length(v_agent)),
      std::string(String_val(v_url), caml_string_length(v_url))));
}
