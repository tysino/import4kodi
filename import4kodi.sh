#!/bin/bash
# import given torrent data (movie or series) into library
# uses kodi file structure
# creates hardlinks

source `dirname $0`/util.sh

# ============= CONFIG ==============
dir_movie="/srv/Movies"
dir_series="/srv/TV"
dir_torrent_movie="/usr/torrent/movie"
dir_torrent_series="/usr/torrent/series"
type=""
fixed_title=""
# loglevels (errors and warnings are always printed to stderr):
# 1: ACCEPT (+new folders) for series, REJECT for movies
# 2: REJECT for series, IGNORE_EXISTING for movies
# 3: IGNORE_EXISTING for series
# 4: debug guess pipeline to stderr
loglevel=2  # default

# possible extensions to look for
vid_ext=(mkv avi mp4 mov)
art_ext=(jpeg jpg tbn png bmp)
sub_ext=(srt sub idx)
# ===================================
# overwrite config with local file
if [[ -f "`dirname $0`/import4kodi.conf" ]]; then
  source "`dirname $0`/import4kodi.conf"
fi

# ============= STATICS =============
options=":t:n:qvh"
year_regex="(1|2)[0-9]{3}"
vid_ext_regex="\.("`join_by '|' "${vid_ext[@]}"`")$"
art_ext_regex="\.("`join_by '|' "${art_ext[@]}"`")$"
sub_ext_regex="\.("`join_by '|' "${sub_ext[@]}"`")$"
# ===================================

# =========== FUNCTIONS =============
usage () {
  echo "$0 [-t series|movie] [-n name] [-v [-v...]] [-q [-q...]] PATH"
  echo "  -t series or movie"
  echo "  -n name (do not guess)"
  echo "  -v increase verbosity"
  echo "  -q decrease verbosity (quiet)"
}

parse_args () {
  # parses variable "type" from args
  while getopts $options opt; do
    case $opt in
      t)
        case $OPTARG in
          series)
            type=series
            ;;
          movie)
            type=movie
            ;;
          *)
            >&2 echo "type not supported: $OPTARG"
            usage
            exit 1
            ;;
        esac
        ;;
      n)
        fixed_title="$OPTARG"
        ;;
      v)
        loglevel=$(($loglevel + 1))
        ;;
      q)
        loglevel=$(($loglevel - 1))
        ;;
      h)
        usage
        exit 0
        ;;
      \?)
        >&2 echo "unknown option: -$OPTARG"
        usage
        exit 1
        ;;
    esac
  done
  linkmsglevel=$loglevel
  if [[ "$type" == "movie" ]]; then
    linkmsglevel=$(($linkmsglevel + 1))
  fi
  # remove processed options
  shift $((OPTIND-1))

  dir_torrent=`realpath "$1"`
  if ! [ -n "$dir_torrent" ]; then
    >&2 echo "missing PATH"
    echo
    usage
    exit 1
  fi

  if [[ "$type" == "" ]]; then
    if [[ "$dir_torrent" == "$dir_torrent_series/"* ]]; then
      type="series"
    elif [[ "$dir_torrent" == "$dir_torrent_movie/"* ]]; then
      type="movie"
    else
      >&2 echo "could not guess type (movie or series) from PATH"
      echo
      usage
      exit 1
    fi
  fi
}

guess_name () {
  # guess the name of the movie/series in given folder
  local path=`basename "$1"`

  # convert dots to spaces
  # e.g. The.Incredible.Hulk.2008.foo.bar --> The Incredible Hulk (2008)
  local guess1=`echo "$path" | grep -oE "^.*\.${year_regex}(\.|$)"`
  [ $loglevel -ge 4 ] && >&2 echo "--- guess 1 'The.Incredible.Hulk.2008.foo.bar' ---"
  [ $loglevel -ge 4 ] && >&2 echo "$guess1"
  guess1=`echo "$guess1" | sed -E "s/\.(${year_regex})\.?$/ \(\1\)/g"`
  [ $loglevel -ge 4 ] && >&2 echo "$guess1"
  guess1=`echo "$guess1" | sed -E "s/\./ /g"`
  [ $loglevel -ge 4 ] && >&2 echo "$guess1"
  if [ ! -z "$guess1" ]; then
    trim_str "$guess1"  #stdout
    return
  fi

  # e.g. The.Incredible.Hulk.(2008).foo.bar --> The Incredible Hulk (2008)
  local guess2=`echo "$path" | grep -oE "^.*\.\(${year_regex}\)"`
  [ $loglevel -ge 4 ] && >&2 echo "--- guess 2 'The.Incredible.Hulk.(2008).foo.bar' ---"
  [ $loglevel -ge 4 ] && >&2 echo "$guess2"
  guess2=`echo "$guess2" | sed -E "s/\.\((${year_regex})\)$/ \(\1\)/g"`
  [ $loglevel -ge 4 ] && >&2 echo "$guess2"
  guess2=`echo "$guess2" | sed -E "s/\./ /g"`
  [ $loglevel -ge 4 ] && >&2 echo "$guess2"
  if [ ! -z "$guess2" ]; then
    trim_str "$guess2"  #stdout
    return
  fi

  # todo: convert everything except digits, letters and parentheses to spaces

  # e.g. The Incredible Hulk (2008) foo bar.baz something --> The Incredible Hulk (2008)
  local fallback=`echo "$path" | grep -oE "^.*\(${year_regex}\)"`
  [ $loglevel -ge 4 ] && >&2 echo "--- fallback ---"
  [ $loglevel -ge 4 ] && >&2 echo "$fallback"
  trim_str "$fallback"  # stdout
}

guess_movie_name () {
  # guess the name of the movie in given folder
  # using advanced checking of files inside folder
  # tries to remove numbering before foldername, if file without number exists in folder
  # (in movie packs the foldernames are often numbered)
  # if removing the number seems right, returns success

  local path=`basename "$1"`
  # e.g. 001.The.Shawshank.Redemption.1994.720p.BluRay.x264-x0r --> The.Shawshank.Redemption.1994.720p.BluRay.x264-x0r
  # if video file with foldername without number exists
  # e.g. The.Shawshank.Redemption.1994.720p.BluRay.x264-x0r.mkv
  if ls "$1/$torrentname_without_number"* 2>/dev/null | grep -qE "$vid_ext_regex"; then
    # then assume that the correct foldername for guessing the movie title is without number
    local guess=`guess_name "$torrentname_without_number"`
    if [ ! -z "$guess" ]; then
      trim_str "$guess"  # stdout
      return 0
    fi
  else
    guess_name "$1"  # fallback
    return 1
  fi
}

guess_series_name () {
  # guess the name of the series in given folder
  # by checking if folder exists (realistic for series when just adding new episodes)
  local guess=`guess_name "$1"`

  # if guess is nonempty but folder does not exist,
  # try removing stuff in parantheses (except year) and check if series folder then exists
  if [ ! -z "$guess" ] && [ ! -d "$dir_series/$guess" ]; then
    [ $loglevel -ge 4 ] && >&2 echo "--- folder '$guess' does not exist, trying to remove stuff in paranthesis ---"
    local year=`echo "$guess" | grep -oE "\(${year_regex}\)"`  # save year for later
    # The Office (US) (2006) --> The Office
    local guess2=`echo "$guess" | sed -E "s/\(.*\)//g"`  # remove everything in parantheses
    local guess2=`trim_str "$guess2"`
    # The Office --> The Office (2006)
    guess2=`trim_str "${guess2} ${year}"`
    [ $loglevel -ge 4 ] && >&2 echo "$guess2"
    # use new guess only when series folder exists
    if [ ! -z "$guess2" ] && [ -d "$dir_series/$guess2" ]; then
      trim_str "$guess2"  # stdout
      return
    fi
  fi
  trim_str "$guess"  # stdout
}

guess_season_number () {
  # S01E003
  local guess=`echo $1 | grep -oE "S[0-9]+E[0-9]+" | sed -E "s/S([0-9]+).*$/\1/g" | sed "s/^0*//g"`
  if [[ "$guess" != "" ]]; then
    echo "$guess"
    return
  fi
  # 01x003
  local guess=`echo $1 | grep -oE "[0-9]+x[0-9]+" | sed -E "s/([0-9]+)x.*$/\1/g" | sed "s/^0*//g"`
  if [[ "$guess" != "" ]]; then
    echo "$guess"
    return
  fi
  # return season number 0 (extras) als fallback
  echo "0"
}

check_name () {
  while [ -z "$name" ]; do
    echo -n "Could not extract name, enter it: "
    read name
  done
  while
    echo -n "Using "
    [ -d "$tgt_dir/$name" ] && echo -n "existing " || echo -n "new "
    echo -n "name '$name'. Are you happy with it? [Y/n] "
    read ans
    if [[ "$ans" == "N" || "$ans" == "n" ]]; then
      echo -n "Enter new name: "
      read name
    elif [[ "$ans" != "" && "$ans" != "Y" && "$ans" != "y" ]]; then
      echo "Please answer with one of [YyNn]"
    fi
    ! [[ "$ans" == "" || "$ans" == "Y" || "$ans" == "y" ]]
  do true; done
}

basename_rel () {
  # removes $2 from beginning of $1
  if [[ "$1" == "$2"* ]]; then
    [[ "$2" == *"/" ]]; local i=$?
    echo "${1:$(( ${#2} + $i)) }"
  else
   echo "$1"
  fi
}

print_matching_names () {
  # print possible matches of guessed name in tgt_dir
  if [ ! -d "$tgt_dir/$name" ]; then
    local -a matching_names=()
    name_clean="$(str_tolower "$(onlyletters "$name")")"
    local -a existing_titles
    mapfile -t existing_titles < <(ls "$tgt_dir")
    local -a matching_i
    mapfile -t matching_i < <(printf -- '%s\n' "${existing_titles[@]}" | sed -E "s/[^a-zA-Z ]+/ /g" | sed -E "s/ +/ /g" | grep -in "$name_clean" | cut -f1 -d:)
    for num in "${matching_i[@]}"; do
      matching_names+=("${existing_titles[$(($matching_i - 1))]}")
    done
    if [[ ${#matching_names[@]} -gt 0 ]]; then
      echo -n "Possible matching titles are: "
      join_by ", " "${matching_names[@]}"
      echo
    fi
  fi
}

import_series () {
  # Relies on the season number being in the filename.
  # Only imports video files (no artwork etc.).
  # Links all video files containing a season number in their name
  # to their respective season folder. Source directory
  # structure is irrelevant.
  # Filenames are kept.

  echo "TYPE: SERIES"

  local -a folders_to_create=()

  if [[ ! -z "$fixed_title" ]]; then
     name="$fixed_title"
  else
    name=`guess_series_name "$dir_torrent"`
  fi
  print_matching_names
  check_name

  local dir_current_series="$dir_series/$name"
  if [ ! -d "$dir_current_series" ]; then
    folders_to_create+=("$dir_current_series")
  fi

  # recursively list all files in folder
  local -a src_files=()
  while read -r line; do
    # only add video files
    if echo "$line" | grep -qiE "$vid_ext_regex"; then
      src_files+=("$line")
    fi
  done < <(find "$dir_torrent" -type f)

  local -a tgt_files=()
  for src_file in "${src_files[@]}"; do
    local f=`basename "$src_file"`
    local season_number=`guess_season_number "$f"`
    local dir_season="$dir_current_series/Season $season_number"
    if [[ "$season_number" == "0" ]]; then
        dir_season="Extra"
    fi
    tgt_files+=("$dir_season/$f")
  done

  # remove already linked files from *_files vars
  local -a src_files_checked=()
  local -a tgt_files_checked=()
  for (( i=0; i<${#src_files[@]}; i++ )); do
    if [ ! -f "${tgt_files[$i]}" ]; then
      src_files_checked+=("${src_files[$i]}")
      tgt_files_checked+=("${tgt_files[$i]}")
      dir_season=`dirname "${tgt_files[$i]}"`
      if [ ! -d "$dir_season" ] && ! array_contains folders_to_create "$dir_season"; then
        folders_to_create+=("$dir_season")
      fi
      [ $linkmsglevel -ge 1 ] && echo -e "\x1B[32mACCEPT: $(basename_rel "${src_files[$i]}" "$dir_torrent") --> $(basename_rel "${tgt_files[$i]}" "$dir_current_series")\x1B[0m"
    else
      [ $linkmsglevel -ge 3 ] && echo -e "\x1B[33mIGNORE_EXISTING: $(basename_rel "${src_files[$i]}" "$dir_torrent") -/-> $(basename_rel "${tgt_files[$i]}" "$dir_current_series")\x1B[0m"
    fi
  done

  # report rejected files
  while read -r file; do
    if ! array_contains src_files "$file"; then
      [ $linkmsglevel -ge 2 ] && echo -e "\x1B[31mREJECT: $(basename_rel "$file" "$dir_torrent")\x1B[0m"
    fi
  done < <(find "$dir_torrent" -maxdepth 1 -type f)


  for dir in "${folders_to_create[@]}"; do
    [ $linkmsglevel -ge 1 ] && echo -e "\x1B[34mNEW_FOLDER '$dir' will be created\x1B[0m"
  done
  if [ "${#src_files_checked[@]}" = 0 ]; then
    echo "Everything is up to date."
    return
  fi
  echo -n "Press enter to create hardlinks..."

  # DANGER ZONE
  read -s  # this line is important for the user to be able to abort
  echo
  echo "Creating directories if any..."
  for dir in "${folders_to_create[@]}"; do
    mkdir "$dir"
  done
  echo "Done. Creating hardlinks..."
  for (( i=0; i<${#src_files_checked[@]}; i++ )); do
    ln "${src_files_checked[$i]}" "${tgt_files_checked[$i]}"
  done
  echo "Done."
}

# remove everything except letters and spaces from torrent name
onlyletters () {
  trim_str "$(echo "$1" | sed -E "s/[^a-zA-Z ]+/ /g" | sed -E "s/ +/ /g")"
}

extract_keywords () {
  # extract keywords from given filename
  # usage: extract_keywords $filename $rem1 $rem2
  # where rem1 and rem2 are strings to try to remove from filename (typically torrent name and movie title (must be onlyletters lowercase!))
  # returns success if one of them could be removed, else failure

  # /some/path/The.Matrix.1999.720p.BRRip.x264-x0r[TRAILER-Theatrical Trailer].mov --> the matrix p brrip x x r trailer theatrical trailer mov
  # /some/path/The Matrix (1999) trailer.mkv --> the matrix trailer mkv
  local file_clean="$(str_tolower "$(onlyletters "$(basename "$1")")")"
  # the matrix p brrip x x r trailer theatrical trailer mov --> trailer theatrical trailer mov
  local file_keywords=`trim_str "$(echo "$file_clean" | sed -E "s/${2}//g")"`
  if [[ "$file_keywords" == "$file_clean" ]]; then  # torrentname not found in filename
    # try to remove movie title from filename
    # the matrix trailer mkv --> trailer mkv
    file_keywords=`trim_str "$(echo "$file_clean" | sed -E "s/${3}//g")"`
  fi
  echo "$file_keywords"
  # return removal success
  [[ "$file_keywords" != "$file_clean" ]]
}

get_ext () {
  # extract extension from filename
  echo "$1" | grep -oP "(?<=\.)[^\.\/]+$"
}

guess_extra_name () {
  # guess name of Extra (removes torrent name etc.)

  # original filename
  local step1="$(trim_str "$(basename "$1")")"
  # remove torrent name
  # e.g. The.Shawshank.Redemption.1994.720p.BluRay.x264-x0r[EXTRA-Hope Springs Eternal, A look back at the Shawshank Redemption].mkv
  #  --> [EXTRA-Hope Springs Eternal, A look back at the Shawshank Redemption].mkv
  local step2="$(trim_str "$step1" | sed -E "s/^$torrentname//g")"
  if [[ "$step2" == "$step1" && $do_remove_number -eq 0 ]]; then
    step2="$(trim_str "$step1" | sed -E "s/^$torrentname_without_number//g")"
  fi
  ext=`get_ext "$step1"`
  # remove brackets
  # e.g. [EXTRA-Hope Springs Eternal, A look back at the Shawshank Redemption].mkv --> EXTRA-Hope Springs Eternal, A look back at the Shawshank Redemption.mkv
  local step3="$(trim_str "$step2" | sed -E "s/\[|\]/ /g" | sed -E "s/ +$vid_ext_regex/\.$ext/g")"
  if [ -z "$step3" ]; then
    echo "$step1"
    return
  fi
  # remove "extra-" prefix
  # e.g. EXTRA-Hope Springs Eternal, A look back at the Shawshank Redemption.mkv --> Hope Springs Eternal, A look back at the Shawshank Redemption.mkv
  local step4="$(trim_str "$step3" |  sed -E "s/^extra[^0-9A-Za-z]+//gi")"
  if [ -z "$step4" ]; then
    echo "$step3"
    return
  fi
  echo "$step4"
}

get_sub_ext () {
  # get subtitle extension (might include "forced")

  echo "$1" | grep -ioE "(\.forced)?$sub_ext_regex"
}

import_movie () {
  # Only links files in root of movie folder.
  # Links video files: movie, trailer, sample, featurette, extras.
  # Links artwork: fanart, landscape, logo, clearlogo, poster.
  # Links subtitles (tries to guess language).
  # Links are renamed to match kodi specs.

  echo "TYPE: MOVIE"

  local -a folders_to_create=()

  if [[ ! -z "$fixed_title" ]]; then
    name="$fixed_title"
    do_remove_number=1
  else
    name=`guess_movie_name "$dir_torrent"`
    do_remove_number=$?  # used by guess_extra_name
  fi
  print_matching_names
  check_name
  # The Matrix (1999) --> The Matrix
  local name_clean=`str_tolower "$(onlyletters "$name")"`
  local torrentname=`basename "$dir_torrent"`
  # /some/path/016.The.Matrix.1999.720p.BRRip.x264-x0r --> The Matrix p BRRip x x r
  local torrentname_clean=`str_tolower "$(onlyletters "$torrentname")"`

  local dir_current_movie="$dir_movie/$name"
  if [ ! -d "$dir_current_movie" ]; then
    folders_to_create+=("$dir_current_movie")
  fi
  local dir_extras="$dir_current_movie/Extras"

  # put file types into their respective bins
  local -a src_vid_files=()
  local -a src_art_files=()
  local -a src_sub_files=()
  while read -r line; do
    if echo "$line" | grep -qiE "$vid_ext_regex"; then
      src_vid_files+=("$line")
    elif echo "$line" | grep -qiE "$art_ext_regex"; then
      src_art_files+=("$line")
    elif echo "$line" | grep -qiE "$sub_ext_regex"; then
      src_sub_files+=("$line")
    fi
  done < <(find "$dir_torrent" -maxdepth 1 -type f)

  # guess file type (movie, artwork, trailer etc.) from file names

  # video guessing pipeline:
  # 1. guess all extra video files (match keyword after removing torrent name or movie title)
  #    - trailer (trailer1, trailer2, etc. if more than one)
  #    - extra (linked to "Extras" folder)
  #    - sample (linked to "Extras" folder)
  # 2. the remaining file is hopefully the movie file
  #    if more than one remain:
  #    2.1 if filename is exactly foldername+ext, take this as movie file
  #    2.2 only keep files which match movie name. if more than one remains, take the one with the shortest name
  # 3. report unmatched files

  local -a src_trailers=()
  local -a src_extras=()
  for file in "${src_vid_files[@]}"; do
    local file_keywords
    file_keywords=`extract_keywords "$file" "$torrentname_clean" "$name_clean"`
    local name_removed=$?
    if [[ "$file_keywords" == *"trailer"* && ( $name_removed == 0 || "$name_clean" != *"trailer"* ) ]]; then
      # only assign to trailers if movie title could be removed first or movie title does not contain "trailer"
      src_trailers+=("$file")
    elif [[ "$file_keywords" == *"sample"* || "$file_keywords" == *"extra"* && ( $name_removed == 0 || "$name_clean" != *"sample"* && "$name_clean" != *"extra"* ) ]]; then
      # only assign to extras if movie title could be removed first or movie title does not contain "sample" or "extra"
      src_extras+=("$file")
    fi
  done
  local -a remaining_vids=()
  for file in "${src_vid_files[@]}"; do
    if ! array_contains src_extras "$file" && ! array_contains src_trailers "$file"; then
      remaining_vids+=("$file")
    fi
  done
  local src_movie_file
  if [[ ${#remaining_vids[@]} == 1 ]]; then
    src_movie_file="${remaining_vids[0]}"  # if only one video remains, take it as movie file
  elif [[ ${#remaining_vids[@]} > 1 ]]; then
    for file in "${remaining_vids[@]}"; do  # for more than one remaining video file
      # if video filename is exactly foldername + ext
      if basename "$file" | grep -qE "^${dir_torrent}${vid_ext_regex}"; then
        src_movie_file="$file"
      fi
    done

    # if still no movie file found
    if [[ "$src_movie_file" == "" ]]; then
      local -a src_movie_file_candidates=()
      for file in "${remaining_vids[@]}"; do
        # only keep filenames which contain the movie title
        if str_tolower "$(onlyletters "$(basename "$file")")" | grep -q "$name_clean"; then
          src_movie_file_candidates+=("$file")
        fi
      done
      local min_i=0
      local min=1000
      for (( i=0; i<${#src_movie_file_candidates[@]}; i++ )); do
        local file="${src_movie_file_candidates[$i]}"
        if [[ ${#file} -lt $min ]]; then
          min_i=$i
          min=${#file}
        fi
      done
      if [[ ${#src_movie_file_candidates[@]} > 0 ]]; then
        src_movie_file="${src_movie_file_candidates[$min_i]}"  # take the file with shortest name
      fi
    fi
  fi

  # artwork guessing by keywords. if more than one found, file is not linked and warning output
  # if no file matches "poster", but an image file with the same filename as the movie exists, take this as poster
  # fanart=...
  # landscape=...
  # logo=...
  # clearlogo=...
  # poster=...
  local -a art_keywords=(fanart landscape clearlogo logo poster)
  local -A src_arts=()
  for file in "${src_art_files[@]}"; do
    local file_keywords
    file_keywords=`extract_keywords "$file" "$torrentname_clean" "$name_clean"`
    local name_removed=$?
    for key in "${art_keywords[@]}"; do
      # if keyword in filename or movie title could not be removed but movie title does not contain keyword anyway
      if [[ "${src_arts[$key]}" == "" && "$file_keywords" == *"$key"* && ( $name_removed == 0 || "$name_clean" != *"$key"* ) ]]; then
        src_arts+=([$key]="$file")
        break
      fi
    done
    # if filename is torrentname, use it as poster
    if basename "$file" | grep -qE "^${torrentname}${art_ext_regex}"; then
      poster_fallback="$file"
    elif array_contains art_ext "$file_keywords"; then  # if just the extension remains after removing torrent/movie name
      poster_fallback="$file"
    fi
  done
  [[ "${src_arts[poster]}" == "" ]] && [[ "$poster_fallback" != "" ]] && src_arts[poster]="$poster_fallback"


  # subtitle guessing pipeline (srt, idx+sub):
  # try to match language prefix before file extension ("en".srt, "de".srt) etc. from name after removing the movie filename
  # if no match, link them with the same name as the movie filename (if only one subtitle of this kind exists)
  local -a src_subs=()
  local -a tgt_subs=()
  local english_regex="(en|english)(forced)?$sub_ext_regex"
  local german_regex="(de|german|deutsch)(forced)?$sub_ext_regex"
  for file in "${src_sub_files[@]}"; do
    local filename=`basename "$file"`
    local ext=`get_sub_ext "$filename"`
    if echo "$filename" | grep -qiE "$english_regex"; then
      src_subs+=("$file")
      tgt_subs+=("$dir_current_movie/$name.English$ext")
    elif echo "$filename" | grep -qiE "$german_regex"; then
      src_subs+=("$file")
      tgt_subs+=("$dir_current_movie/$name.German$ext")
    elif ! array_contains tgt_subs "$dir_current_movie/$name.$ext"; then  # first encountered remaining file gets added, others not
      src_subs+=("$file")
      tgt_subs+=("$dir_current_movie/$name$ext")
    fi
  done

  # assign src files to targets
  local -a src_extras_checked=()
  local -a src_trailers_checked=()
  local src_movie_file_checked
  local -A src_arts_checked=()
  local -a src_subs_checked=()

  local -a tgt_extras_checked=()
  local -a tgt_trailers_checked=()
  local tgt_movie_file_checked
  local -A tgt_arts_checked=()
  local -a tgt_subs_checked=()

  for extra in "${src_extras[@]}"; do
    local new_tgt_extra_name=`guess_extra_name "$extra"`
    local new_tgt_extra="$dir_extras/$new_tgt_extra_name"
    if [ ! -f "$new_tgt_extra" ]; then
      src_extras_checked+=("$extra")
      tgt_extras_checked+=("$new_tgt_extra")
      if [[ "$(basename "$extra")" == "$new_tgt_extra_name" ]]; then
        [ $linkmsglevel -ge 1 ] && echo -e "\x1B[32mACCEPT: $(basename "$extra") --> $(basename "$dir_extras")/\x1B[0m"
      else
        [ $linkmsglevel -ge 1 ] && echo -e "\x1B[32mACCEPT: $(basename "$extra") --> $(basename "$dir_extras")/$new_tgt_extra_name\x1B[0m"
      fi
    else
      [ $linkmsglevel -ge 3 ] && echo -e "\x1B[33mIGNORE_EXISTING: $(basename "$extra") -/-> $(basename_rel "$new_tgt_extra" "$dir_current_movie")\x1B[0m"
    fi
  done
  if ! [ -d "$dir_extras" ] && [[ ${#src_extras_checked[@]} -gt 0 ]]; then
    folders_to_create+=("$dir_extras")
  fi
  if [[ "${#src_trailers[@]}" == 1 ]]; then
    local ext=`get_ext "${src_trailers[0]}"`
    local new_tgt_trailer="$dir_current_movie/$name-trailer.$ext"
    if [ ! -f "$new_tgt_trailer" ]; then
      src_trailers_checked+=("${src_trailers[0]}")
      tgt_trailers_checked+=("$new_tgt_trailer")
      [ $linkmsglevel -ge 1 ] && echo -e "\x1B[32mACCEPT: $(basename "${src_trailers[0]}") --> $(basename_rel "$new_tgt_trailer" "$dir_current_movie")\x1B[0m"
    else
      [ $linkmsglevel -ge 3 ] && echo -e "\x1B[33mIGNORE_EXISTING: $(basename "${src_trailers[0]}") -/-> $(basename_rel "$new_tgt_trailer" "$dir_current_movie")\x1B[0m"
    fi
  else
    for (( i=0; i<${#src_trailers[@]}; i++ )); do
      local ext=`get_ext "${src_trailers[$i]]"`
      local new_tgt_trailer="$dir_current_movie/$name-trailer$i.$ext"
      if [ ! -f "$new_tgt_trailer" ]; then
        src_trailers_checked+=("${src_trailers[$i]}")
        tgt_trailers_checked+=("$new_tgt_trailer")
        [ $linkmsglevel -ge 1 ] && echo -e "\x1B[32mACCEPT: $(basename "${src_trailers[$i]}") --> $(basename_rel "$new_tgt_trailer" "$dir_current_movie")\x1B[0m"
      else
      [ $linkmsglevel -ge 3 ] && echo -e "\x1B[33mIGNORE_EXISTING: $(basename "${src_trailers[$i]}") -/-> $(basename_rel "$new_tgt_trailer" "$dir_current_movie")\x1B[0m"
      fi
    done
  fi
  if [[ "$src_movie_file" != "" ]]; then
    local ext=`get_ext "$src_movie_file"`
    local new_tgt_movie_file="$dir_current_movie/$name.$ext"
    if [ ! -f "$new_tgt_movie_file" ]; then
      src_movie_file_checked="$src_movie_file"
      tgt_movie_file_checked="$new_tgt_movie_file"
      [ $linkmsglevel -ge 1 ] && echo -e "\x1B[32mACCEPT: $(basename "$src_movie_file_checked") --> $(basename_rel "$tgt_movie_file_checked" "$dir_current_movie")\x1B[0m"
    else
      [ $linkmsglevel -ge 3 ] && echo -e "\x1B[33mIGNORE_EXISTING: $(basename "$src_movie_file") -/-> $(basename_rel "$new_tgt_movie_file" "$dir_current_movie")\x1B[0m"
    fi
  fi
  for key in "${!src_arts[@]}"; do
    local ext=`get_ext "${src_arts[$key]}"`
    local new_tgt_art="$dir_current_movie/$name-$key.$ext"
    if [ ! -f "$new_tgt_art" ]; then
      src_arts_checked+=(["$key"]="${src_arts[$key]}")
      tgt_arts_checked+=(["$key"]="$new_tgt_art")
      [ $linkmsglevel -ge 1 ] && echo -e "\x1B[32mACCEPT: $(basename "${src_arts[$key]}") --> $(basename_rel "$new_tgt_art" "$dir_current_movie")\x1B[0m"
    else
      [ $linkmsglevel -ge 3 ] && echo -e "\x1B[33mIGNORE_EXISTING: $(basename "${src_arts[$key]}") -/-> $(basename_rel "$new_tgt_art" "$dir_current_movie")\x1B[0m"
    fi
  done
  for (( i=0; i<${#src_subs[@]}; i++ )); do
    if [ ! -f "${tgt_subs[$i]}" ]; then
      src_subs_checked+=("${src_subs[$i]}")
      tgt_subs_checked+=("${tgt_subs[$i]}")
      [ $linkmsglevel -ge 1 ] && echo -e "\x1B[32mACCEPT: $(basename "${src_subs[$i]}") --> $(basename_rel "${tgt_subs[$i]}" "$dir_current_movie")\x1B[0m"
    else
      [ $linkmsglevel -ge 3 ] && echo -e "\x1B[33mIGNORE_EXISTING: $(basename "${src_subs[$i]}") -/-> $(basename_rel "${tgt_subs[$i]}" "$dir_current_movie")\x1B[0m"
    fi
  done
  for folder in "${folders_to_create[@]}"; do
    [ $linkmsglevel -ge 1 ] && echo -e "\x1B[34mNEW_FOLDER '$folder' will be created.\x1B[0m"
  done

  # report ignored files
  while read -r line; do
    if ! array_contains src_extras "$line" && ! array_contains src_trailers "$line" && ! [[ "$line" == "$src_movie_file" ]] && ! array_contains src_arts "$line" && ! array_contains src_subs "$line"; then
      [ $linkmsglevel -ge 2 ] && echo -e "\x1B[31mREJECT: $(basename "$line")\x1B[0m"
    fi
  done < <(find "$dir_torrent" -maxdepth 1 -type f)

  if [[ "$src_movie_file_checked" == "" ]] && [[ ${#src_trailers_checked[@]} -eq 0 ]] && [[ ${#src_extras_checked[@]} -eq 0 ]] && [[ ${#src_arts_checked[@]} -eq 0 ]] && [[ ${#src_subs_checked[@]} -eq 0 ]]; then
    echo "Everything is up to date."
    return
  fi
  echo -n "Press enter to create hardlinks..."

  # DANGER ZONE
  read -s  # this line is important for the user to be able to abort
  echo
  if [[ ${#folders_to_create[@]} -gt 0 ]]; then
    echo -n "Creating directories..."
    for dir in "${folders_to_create[@]}"; do
      mkdir "$dir"
    done
    echo " Done."
  fi
  if [[ "$src_movie_file_checked" != "" ]]; then
    echo -n "Creating hardlink for main movie file..."
    ln "$src_movie_file_checked" "$tgt_movie_file_checked"
    echo " Done."
  fi
  if [[ ${#src_extras_checked[@]} -gt 0 ]]; then
    echo -n "Creating hardlinks for Extras..."
    for (( i=0; i<${#src_extras_checked[@]}; i++ )); do
      ln "${src_extras_checked[$i]}" "${tgt_extras_checked[$i]}"
    done
    echo " Done."
  fi
  if [[ ${#src_trailers_checked[@]} -gt 0 ]]; then
    echo -n "Creating hardlinks for trailers..."
    for (( i=0; i<${#src_trailers_checked[@]}; i++ )); do
      ln "${src_trailers_checked[$i]}" "${tgt_trailers_checked[$i]}"
    done
    echo " Done."
  fi
  if [[ ${#src_arts_checked[@]} -gt 0 ]]; then
    echo -n "Creating hardlinks for Artworks..."
    for key in "${!src_arts_checked[@]}"; do
      ln "${src_arts_checked[$key]}" "${tgt_arts_checked[$key]}"
    done
    echo " Done."
  fi
  if [[ ${#src_subs_checked[@]} -gt 0 ]]; then
    echo -n "Creating hardlinks for Subtitles..."
    for (( i=0; i<${#src_subs_checked[@]}; i++ )); do
      ln "${src_subs_checked[$i]}" "${tgt_subs_checked[$i]}"
    done
    echo " Done."
  fi
}
# ======================================

# ================ MAIN ================
parse_args "$@"

if ! [ -d "$dir_torrent" ]; then
  >&2 echo "Source directory not found: '$dir_torrent'"
  exit 1
fi
torrentname_without_number="$(basename "$dir_torrent" | sed -E "s/^[0-9]+\.//g")"  # used by guess_*

case $type in
  series)
    tgt_dir="$dir_series"  # used by check_name()
    if ! [ -d "$tgt_dir" ]; then
      >&2 echo "Target directory not found: '$tgt_dir'"
      exit 1
    fi
    import_series
    ;;
  movie)
    tgt_dir="$dir_movie"  # used by check_name()
    if ! [ -d "$tgt_dir" ]; then
      >&2 echo "Target directory not found: '$tgt_dir'"
      exit 1
    fi
    import_movie
    ;;
esac
# =======================================
