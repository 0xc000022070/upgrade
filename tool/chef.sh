CHEF_ON=0
CHEF_ROWS=0
CHEF_TTY=""

readonly CHEF_QUIPS=(
  "Reducing the Gradle sauce..."
  "Deglazing the pan with Kotlin..."
  "Folding in the dart2aot..."
  "Seasoning generously with R8..."
  "Letting the shaders rest..."
  "Whisking the daemon. It whisks back."
  "Who left a .dart_tool in my oven?"
  "Taste... needs more versionCode."
  "Zest of debug.keystore, a pinch of apksigner."
  "Do not open the oven. Do NOT open the oven."
)

chef_open() {
  [[ -z $CHEF_TTY ]] || return 0
  if [[ -t 1 && -z ${DEPLOY_PLAIN:-} && ${TERM:-dumb} != dumb ]]; then
    CHEF_ON=1
    printf '\033[?25l'
  fi
  if (: </dev/tty) 2>/dev/null; then
    exec {CHEF_TTY}</dev/tty
  fi
}

chef_close() {
  ((CHEF_ON)) && printf '\033[?25h'
  CHEF_ON=0
  CHEF_ROWS=0
  if [[ -n $CHEF_TTY ]]; then
    exec {CHEF_TTY}<&-
    CHEF_TTY=""
  fi
}

chef_clear() {
  if ((CHEF_ROWS > 0)); then
    printf '\033[%dA\r\033[J' "$CHEF_ROWS"
    CHEF_ROWS=0
  fi
}

# Fails at once when there is no terminal to read.
chef_key() {
  [[ -n $CHEF_TTY ]] || return 1
  IFS= read -rsn1 -t 0.25 -u "$CHEF_TTY" "$1"
}

chef_clock() {
  printf '%d:%02d' $(($1 / 60)) $(($1 % 60))
}

chef_quip() {
  echo "${CHEF_QUIPS[$((($1 / 24) % ${#CHEF_QUIPS[@]}))]}"
}

chef_oven() {
  local waited=$1 eta=$2 width=20 fill
  if [[ -z $eta ]] || ((eta <= 0)); then
    echo "oven $(chef_clock "$waited")"
    return
  fi
  fill=$((waited * width / eta))
  ((fill <= width)) || fill=$width
  local bar
  bar=$(printf '%*s' "$fill" '' | tr ' ' '=')
  ((fill < width)) && bar+=">"
  bar+=$(printf '%*s' $((width - ${#bar})) '' | tr ' ' '.')
  echo "oven [$bar] $(chef_clock "$waited") / ~$(chef_clock "$eta")"
}

readonly CHEF_W=18

readonly CHEF_IDLE_POSES=(read snooze knife read)
readonly CHEF_IDLE=(
  "Kitchen's clean. Watching HEAD %s..."
  "zZz... wake me up when you commit."
  "Sharpening the knives for the next commit."
  "Reading tonight's recipe: %s"
)

chef_scene() {
  local pose=$1 t=$2 face arms tail='<_/' ant='~~' ant2='~~'
  case $pose in
  stir) ((t % 16 == 0)) && face="- _ -" || face="o _ o" ;;
  sweat) ((t % 2)) && face="O _ O" || face="o _ O" ;;
  ask | walk | knife | read) face="o _ o" ;;
  snooze) face="- _ -" ;;
  settle) ((t / 4 % 2)) && face="o _ o" || face="O _ O" ;;
  bow) face="^ v ^" ;;
  fire) ((t % 2)) && face="O o O" || face="x _ x" ;;
  toss) face="> _ <" ;;
  shelf) face=". _ ." ;;
  sad) face="; _ ;" ;;
  esac
  case $pose in
  stir | sweat | toss) arms='        /(   )\___' ;;
  ask | walk) arms='        /(   )\_/' ;;
  knife | read) arms='        /(   )\__' ;;
  bow | fire) arms='       \\(   )//' ;;
  *) arms='        /(   )\' ;;
  esac
  if ((t % 2)); then
    ant='-~' ant2='~-'
    [[ $pose == ask || $pose == walk || $pose == bow ]] && tail='>_/'
  fi
  [[ $pose == fire ]] && ant='!!' ant2='!!'
  [[ $pose == sad ]] && ant='__' ant2='__'
  CHEF_L=(
    '   \     .-^-.'
    '    \    (___)'
    "      $ant($face)$ant2"
    "$arms"
    '         (___)'
    '          (__)'
    '           (_)'
    "         $tail"
  )

  local s1=' ) ) )' s2='( ( ( ' spoon='/' soup='~o~~~' flame='^^^^^'
  if ((t % 2)); then
    s1='( ( ( ' s2=' ) ) )' flame='^ ^ ^'
  fi
  case $((t % 4)) in
  1 | 3) spoon='|' ;;
  2) spoon='\' ;;
  esac
  ((t % 3 == 1)) && soup='~~~o~'
  ((t % 3 == 2)) && soup='o~~~~'
  case $pose in
  stir | sweat)
    CHEF_P=("  $s1" " $s2" "   $spoon" ".-----." "|$soup|" "\\$flame/" "" "")
    if [[ $pose == sweat ]]; then
      CHEF_P[0]+="   ; ;"
    fi
    ;;
  ask)
    CHEF_P=("" " .'_'." "(_____)" "" "" "" "" "")
    if ((t / 2 % 2)); then
      CHEF_P[0]="   ?"
    fi
    ;;
  bow)
    if ((t % 2)); then
      CHEF_P=("  *   .   *" "    .   *" "  *    .   *" "" "" "" "" "")
    else
      CHEF_P=("  .   *   ." "    *   ." "  .   *    ." "" "" "" "" "")
    fi
    ;;
  fire) CHEF_P=("   ) (  ) (" "  ( )) ( )" "   )(  )(" "  .-----." "  |#####|" "  \\^^^^^/" "" "") ;;
  toss) CHEF_P=("" "   ~   ~" "  ~ \\   ~" "._______." "|       | ~" "~~~~~~~~~~~~~~" "" "") ;;
  shelf) CHEF_P=("" "   .'_'." "  (_____)" " =========" "    |   |" "" "" "") ;;
  snooze)
    case $((t / 4 % 3)) in
    0) CHEF_P=("" "    z" "" "" "" "" "" "") ;;
    1) CHEF_P=("     Z" "    z" "" "" "" "" "" "") ;;
    2) CHEF_P=("   Z" "     Z" "    z" "" "" "" "" "") ;;
    esac
    ;;
  knife)
    if ((t % 2)); then
      CHEF_P=("" "" "   *" "_=|====>" "" "" "" "")
    else
      CHEF_P=("" "" "    ." "_=|===>-" "" "" "" "")
    fi
    ;;
  read)
    CHEF_P=("" "" " _______" "|  git  |" "| log   |" "|_______|" "" "")
    if ((t / 8 % 2)); then
      CHEF_P[4]="|  -1   |"
    fi
    ;;
  settle) CHEF_P=("" "" "" "" "" "" "" "") ;;
  sad) CHEF_P=("" "" "      .---." "      | X |" "      |   |" "      |___|" " (_____)" "") ;;
  esac
}

chef_walk() {
  local t=$1 lane=20 pos i pad line
  pos=$((t % lane))
  printf -v pad '%*s' "$pos" ''
  chef_scene walk "$t"
  CHEF_L[0]=${CHEF_L[0]/\\/ }
  CHEF_L[1]=${CHEF_L[1]/\\/ }
  local carried=("" " .'_'." "(_____)" "" "" "" "" "")
  local phone=("" "" "" ".---." "|   |" "| U |" "|___|" "")
  for i in 0 1 2 3 4 5 6 7; do
    printf -v line '%s%-*s%-8s' "$pad" "$CHEF_W" "${CHEF_L[$i]}" "${carried[$i]}"
    printf -v line '%-*s%s' $((lane + CHEF_W + 8)) "$line" "${phone[$i]}"
    CHEF_L[$i]=$line
    CHEF_P[$i]=""
  done
}

chef_draw() {
  ((CHEF_ON)) || return 0
  local pose=$1 t=$2 bubble=$3 status=${4:-} step=${5:-}
  local cols room i plain out="" w=$'\033[38;5;209m' y=$'\033[33m' g=$'\033[90m'
  local r=$'\033[91m' c=$'\033[38;5;154m' m=$'\033[95m' off=$'\033[0m'
  ((CHEF_ROWS > 0)) || printf '\033[?25l'
  cols=$(tput cols 2>/dev/null || echo 80)
  room=$((cols - 1))
  if [[ $pose == walk ]]; then
    chef_walk "$t"
  else
    chef_scene "$pose" "$t"
  fi

  local text=${bubble:0:$((room - 4))} under over
  printf -v under '%*s' $((${#text} + 2)) ''
  over=${under// /-}
  under=${under// /_}
  local lines=(
    "$c $under$off"
    "$c< $text >$off"
    "$c $over$off"
  )
  local prop_color=$y
  case $pose in
  fire) prop_color=$r ;;
  bow) prop_color=$m ;;
  esac
  for i in 0 1 2 3 4 5 6 7; do
    printf -v plain '%-*s%s' "$CHEF_W" "${CHEF_L[$i]}" "${CHEF_P[$i]}"
    plain=${plain:0:$room}
    plain=${plain%"${plain##*[! ]}"}
    if [[ $pose == stir || $pose == sweat ]] && ((i < 2)); then
      lines+=("$w${plain:0:$CHEF_W}$g${plain:$CHEF_W}$off")
    else
      lines+=("$w${plain:0:$CHEF_W}$prop_color${plain:$CHEF_W}$off")
    fi
  done
  [[ -n $status ]] && lines+=("$c${status:0:$room}$off")
  [[ -n $step ]] && lines+=("$g${step:0:$room}$off")

  ((CHEF_ROWS > 0)) && out=$'\033['"${CHEF_ROWS}A"
  for plain in "${lines[@]}"; do
    out+=$'\r\033[2K'"$plain"$'\n'
  done
  ((${#lines[@]} < CHEF_ROWS)) && out+=$'\033[J'
  printf '%s' "$out"
  CHEF_ROWS=${#lines[@]}
}

chef_end() {
  chef_draw "$@"
  CHEF_ROWS=0
}
