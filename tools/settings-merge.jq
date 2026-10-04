# settings-merge.jq – desired-state merge of a settings fragment into a Claude
# Code settings.json. Shared by toolbox.sh and toolbox.ps1 (catalog type
# "settings") so both ports apply byte-identical semantics.
#
# Run with -n. Inputs:
#   $frag  the fragment, via --slurpfile (so $frag[0])
#   $cur   the current settings, via --slurpfile (missing file: --argjson cur '{}')
#   $mode  apply | strip | state
#
# Semantics:
#   apply  objects merge recursively, arrays gain the fragment's missing
#          elements (order kept, no duplicates), scalars take the fragment value
#   strip  remove exactly the fragment's keys/elements – a value is removed only
#          when it equals the fragment's; a container emptied by the strip
#          disappears, one that was already empty stays
#   state  "ok" (fragment fully applied), "partial" (some of it present) or
#          "none" (nothing of it present)

def apply($a; $b):
  if ($a | type) == "object" and ($b | type) == "object" then
    reduce ($b | keys_unsorted[]) as $k ($a; .[$k] = apply($a[$k]; $b[$k]))
  elif ($a | type) == "array" and ($b | type) == "array" then
    $a + ($b - $a)
  else $b end;

def covered($a; $b):
  if ($b | type) == "object" then
    ($a | type) == "object" and all($b | keys_unsorted[]; . as $k | covered($a[$k]; $b[$k]))
  elif ($b | type) == "array" then
    ($a | type) == "array" and (($b - $a) | length) == 0
  else $a == $b end;

def strip($a; $b):
  if ($a | type) == "object" and ($b | type) == "object" then
    (reduce ($b | keys_unsorted[]) as $k ($a;
        if has($k) then
          strip(.[$k]; $b[$k]) as $v
          | if $v == null then del(.[$k]) else .[$k] = $v end
        else . end))
    | if length == 0 and ($a | length) > 0 then null else . end
  elif ($a | type) == "array" and ($b | type) == "array" then
    ($a - $b) | if length == 0 and ($a | length) > 0 then null else . end
  elif $a == $b then null
  else $a end;

($cur | if type == "array" then (.[0] // {}) else . end) as $c
| $frag[0] as $f
| if ($f | type) != "object" then error("settings fragment must be a JSON object")
  elif $mode == "apply" then apply($c; $f)
  elif $mode == "strip" then (strip($c; $f) // {})
  elif $mode == "state" then
    if covered($c; $f) then "ok"
    elif (strip($c; $f) // {}) == $c then "none"
    else "partial" end
  else error("mode must be apply, strip or state") end
