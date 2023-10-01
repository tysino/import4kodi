trim_str () {
  echo "$1" | sed 's/ *$//g' | sed 's/^ *//g'
}

str_tolower () {
  echo "$1" | tr '[:upper:]' '[:lower:]'
}

join_by () {
  local d=${1-} f=${2-}
  if shift 2; then
    printf %s "$f" "${@/#/$d}"
  fi
}

array_contains () {
    # usage: array_contains array_var_name "element with spaces"
    local array="$1[@]"
    local seeking=$2
    local in=1
    for element in "${!array}"; do
        if [[ $element == "$seeking" ]]; then
            in=0
            break
        fi
    done
    return $in
}
