#!/bin/bash
# Первый параметр $1 - это температура, $2 - это номер первой подключённой платы, $3 - это номер второй подключённой платы

set -euo pipefail # ключ -e завершает работу, если есть ошибка; -u рассматривает не объявленные переменные как ошибку; -o pipefail если хоть один конвейер упадёт, вся цепочка вернёт ошибку
declare -r TESTS_BIN_FILES_PATH="./generated_test"
declare -ri TEST_FILE_SIZE=1024 # размер тестового файла в байтах
declare -r AMBIENT_TEMPERATURE="${1:-temperature_argument_not_set}" # Окружающая температура
declare -r UART_TEST_LOG_FILE="UART_test_$AMBIENT_TEMPERATURE.tsv"
declare -r TMP_INPUT_UART_FILE="temp_UART_output.bin"
declare -r TMP_EXPECTED_UART_FILE="temp_UART_expected.bin"
declare -Ar TESTED_WORDS=(
    [cs5]=$((2#10101))
    [cs6]=$((2#101010))
    [cs7]=$((2#1010101))
    [cs8]=$((2#10101010))
)
declare -r OPEN_PORT_TIME="0.2"
declare -r READ_TIMEOUT="5"
# Доступные параметры для CH340G
declare -ri baud_rates=(115200)
declare -r character_size_stty=(cs5 cs6 cs7 cs8)
declare -Ar character_sizes=(
    [cs5]=5
    [cs6]=6
    [cs7]=7
    [cs8]=8
)
declare -r stop_bits_stty=("-cstopb" "cstopb")
declare -Ar stop_bits=(
    [-cstopb]=1
    [cstopb]=2
)
declare -r flow_control="-crtscts" # отключено
declare -Ar parity_modes=(
    ["none"]="-parenb"
    ["even"]="parenb -parodd"
    ["odd"]="parenb parodd"
)

# Проверяем, сколько обнаружено USB - UART преобразователей
find /dev/ -maxdepth 1 -name "ttyUSB*"

declare -a paths_USB_UART
mapfile -t paths_USB_UART < <(find /dev/ -maxdepth 1 \( -name 'ttyUSB*' -o -name 'ttyACM*' \) 2>/dev/null) # преобразователь определяется в системе иногда как ttyUSB, а иногда как ttyACM
declare -ri COUNT_USB_UART=${#paths_USB_UART[@]}

if [ "$COUNT_USB_UART" -eq 0 ]; then
    echo "Преобразователей USB - UART не обнаружено. Прекращаю свою работу"
    exit 1
elif [ "$COUNT_USB_UART" -gt 2 ]; then
    echo "Преобразователей USB - UART более 2-х штук. Прекращаю свою работу"
    exit 1
else
    echo "Количество преобразователей: $COUNT_USB_UART"
fi

declare path_USB_UART_1 path_USB_UART_2
if [ "$COUNT_USB_UART" -eq 1 ]; then
    path_USB_UART_1="${paths_USB_UART[0]}"
    path_USB_UART_2="${paths_USB_UART[0]}"
else
    path_USB_UART_1="${paths_USB_UART[0]}"
    path_USB_UART_2="${paths_USB_UART[1]}"
fi

transmit_and_receive() {
    local receive_port=$1
    local transmit_port=$2
    local expected_file=$3
    local expected_size
    local reader_pid

    expected_size=$(wc -c < "$expected_file")
    : > "$TMP_INPUT_UART_FILE"

    timeout "$READ_TIMEOUT" dd if="$receive_port" of="$TMP_INPUT_UART_FILE" bs=1 count="$expected_size" status=none &
    reader_pid=$!
    sleep "$OPEN_PORT_TIME" # Даем порту время открыться
    cat "$expected_file" > "$transmit_port"
    wait "$reader_pid"
}

test_file_needs_generation() {
    local test_file=$1
    local actual_size

    if ! [ -f "$test_file" ]; then
        return 0
    fi

    actual_size=$(wc -c < "$test_file")
    [ "$actual_size" -ne "$TEST_FILE_SIZE" ]
}


# Опробование
echo "Устанавливаю настройки для $path_USB_UART_1: raw 9600 ${character_size_stty[3]} ${stop_bits_stty[0]} ${parity_modes["none"]} -echo"
stty -F "$path_USB_UART_1" raw "9600" "${character_size_stty[3]}" "${stop_bits_stty[0]}" "${parity_modes["none"]}" -echo
echo "Устанавливаю настройки для $path_USB_UART_2: raw 9600 ${character_size_stty[3]} ${stop_bits_stty[0]} ${parity_modes["none"]} -echo"
stty -F "$path_USB_UART_2" raw "9600" "${character_size_stty[3]}" "${stop_bits_stty[0]}" "${parity_modes["none"]}" -echo

echo -e "\nОпробование. Перекрёстный тест в прямом направлении:"
printf "%s" "${TESTED_WORDS[cs8]}" > "$TMP_EXPECTED_UART_FILE"
echo "Передаю данные: ${TESTED_WORDS[cs8]}"
if transmit_and_receive "$path_USB_UART_1" "$path_USB_UART_2" "$TMP_EXPECTED_UART_FILE" && cmp -s "$TMP_EXPECTED_UART_FILE" "$TMP_INPUT_UART_FILE"; then
    echo "УСПЕШНАЯ ПЕРЕДАЧА ДАННЫХ ✔️"
else
    echo "❌❌❌ ОШИБКА ПЕРЕДАЧИ ДАННЫХ. ТЕСТ НЕ ПРОШЁЛ ОПРОБОВАНИЕ ❌❌❌"
    exit 1
fi
printf "Полученные данные: %s \n" "$(cat "$TMP_INPUT_UART_FILE")"

echo -e "\nОпробование. Перекрёстный тест в обратном направлении:"
printf "%s" "${TESTED_WORDS[cs8]}" > "$TMP_EXPECTED_UART_FILE"
echo "Передаю данные: ${TESTED_WORDS[cs8]}"
if transmit_and_receive "$path_USB_UART_2" "$path_USB_UART_1" "$TMP_EXPECTED_UART_FILE" && cmp -s "$TMP_EXPECTED_UART_FILE" "$TMP_INPUT_UART_FILE"; then
    echo "УСПЕШНАЯ ПЕРЕДАЧА ДАННЫХ ✔️"
else
    echo "❌❌❌ ОШИБКА ПЕРЕДАЧИ ДАННЫХ. ТЕСТ НЕ ПРОШЁЛ ОПРОБОВАНИЕ ❌❌❌"
    exit 1
fi
printf "Полученные данные: %s \n" "$(cat "$TMP_INPUT_UART_FILE")"



# Проверяем, есть ли у нас сгенерированные тесты, если нет - генерируем их
if ! [ -d "$TESTS_BIN_FILES_PATH" ]; then
    echo -e "\nПапка $TESTS_BIN_FILES_PATH не существует. Создаю её:"
    mkdir -p "$TESTS_BIN_FILES_PATH"
fi
if test_file_needs_generation "$TESTS_BIN_FILES_PATH/test_cs5.bin"; then
    echo "Файл для теста CS5 не существует или имеет неправильный размер. Генерирую тест"
    od -An -v -tu1 -N $TEST_FILE_SIZE /dev/urandom | awk '{for(i=1;i<=NF;i++) printf "%c", $i%32}' > "$TESTS_BIN_FILES_PATH/test_cs5.bin"
fi
if test_file_needs_generation "$TESTS_BIN_FILES_PATH/test_cs6.bin"; then
    echo "Файл для теста CS6 не существует или имеет неправильный размер. Генерирую тест"
    od -An -v -tu1 -N $TEST_FILE_SIZE /dev/urandom | awk '{for(i=1;i<=NF;i++) printf "%c", $i%64}' > "$TESTS_BIN_FILES_PATH/test_cs6.bin"
fi
if test_file_needs_generation "$TESTS_BIN_FILES_PATH/test_cs7.bin"; then
    echo "Файл для теста CS7 не существует или имеет неправильный размер. Генерирую тест"
    od -An -v -tu1 -N $TEST_FILE_SIZE /dev/urandom | awk '{for(i=1;i<=NF;i++) printf "%c", $i%128}' > "$TESTS_BIN_FILES_PATH/test_cs7.bin"
fi
if test_file_needs_generation "$TESTS_BIN_FILES_PATH/test_cs8.bin"; then
    echo "Файл для теста CS8 не существует или имеет неправильный размер. Генерирую тест"
    dd if=/dev/urandom of="$TESTS_BIN_FILES_PATH/test_cs8.bin" bs=1 count=$TEST_FILE_SIZE status=none
fi



# Проведение тестов
declare BOARD_NAME_1="${2:-X}" # Номер 1-й платы. Если $2 задан и не пустой → берётся $2; если не задан или пустой → подставляется "X"
declare BOARD_NAME_2="${3:-X}" # Номер 2-й платы

printf "" > "$UART_TEST_LOG_FILE" # Стираем старую информацию из лог-файла
printf "\n%s\n" "Запускаем тесты с различными комбинациями параметров UART"
printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
    "Температура окружающей среды" \
    "Номер передающей платы" \
    "Номер принимающей платы" \
    "Размер передаваемой информации"  \
    "Baud rate" \
    "Data bits" \
    "Stop bits" \
    "Parity" \
    "Flow control" \
    "Итог" \
    >> "$UART_TEST_LOG_FILE"

declare test_result # метка PASS или FAIL
declare -i is_test_valid=1  # флаг статуса прохождения теста
for baud_rate in "${baud_rates[@]}"; do
    for stop_bits_key in "${!stop_bits[@]}"; do
        for character_size_key in "${!character_sizes[@]}"; do
            for parity_mode_key in "${!parity_modes[@]}"; do
                run_test() {
                    local path_USB_UART_1=$1
                    local path_USB_UART_2=$2
                    local BOARD_NAME_1=$3
                    local BOARD_NAME_2=$4
                    local test_text_sequence=$5
                    local test_payload_type=$6
                    local test_text_type=$7
                    local expected_file
                    local -a parity_options
                    read -r -a parity_options <<< "${parity_modes[$parity_mode_key]}"

                    stty -F "$path_USB_UART_1" raw "$baud_rate" "$character_size_key" "${parity_options[@]}" "$stop_bits_key" "$flow_control" -echo inpck -parmrk ignpar
                    stty -F "$path_USB_UART_2" raw "$baud_rate" "$character_size_key" "${parity_options[@]}" "$stop_bits_key" "$flow_control" -echo inpck -parmrk ignpar

                    if [ "$test_payload_type" = "file" ]; then
                        expected_file=$test_text_sequence
                    else
                        printf "%s" "$test_text_sequence" > "$TMP_EXPECTED_UART_FILE"
                        expected_file=$TMP_EXPECTED_UART_FILE
                    fi

                    if transmit_and_receive "$path_USB_UART_1" "$path_USB_UART_2" "$expected_file" && cmp -s "$expected_file" "$TMP_INPUT_UART_FILE"; then
                        test_result="PASS ✔️"
                    else
                        test_result="FAIL ❌"
                        is_test_valid=0
                    fi

                    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
                        "$AMBIENT_TEMPERATURE °C" \
                        "№ $BOARD_NAME_2" \
                        "№ $BOARD_NAME_1" \
                        "$test_text_type"  \
                        "$baud_rate бод" \
                        "${character_sizes[$character_size_key]} бит" \
                        "${stop_bits[$stop_bits_key]} бит(-а)" \
                        "$parity_mode_key" \
                        "Отключено" \
                        "$test_result" \
                        >> "$UART_TEST_LOG_FILE"
                }

                run_test "$path_USB_UART_1" "$path_USB_UART_2" "$BOARD_NAME_1" "$BOARD_NAME_2" "${TESTED_WORDS[$character_size_key]}" "word" "Слово"
                run_test "$path_USB_UART_2" "$path_USB_UART_1" "$BOARD_NAME_2" "$BOARD_NAME_1" "${TESTED_WORDS[$character_size_key]}" "word" "Слово"
                run_test "$path_USB_UART_1" "$path_USB_UART_2" "$BOARD_NAME_1" "$BOARD_NAME_2" "$TESTS_BIN_FILES_PATH/test_$character_size_key.bin" "file" "Текст $TEST_FILE_SIZE байт"
                run_test "$path_USB_UART_2" "$path_USB_UART_1" "$BOARD_NAME_2" "$BOARD_NAME_1" "$TESTS_BIN_FILES_PATH/test_$character_size_key.bin" "file" "Текст $TEST_FILE_SIZE байт"

            done
        done
    done
done

if [ "$is_test_valid" -eq 1 ]; then
    echo -e "\n🏁 Тест выполнен успешно! 🏁"
else
    echo -e "\n⚠️ Тест закончился неудачей на одном или нескольких этапах! Подробности смотреть в tsv-файле. ⚠️"
fi

rm -f "$TMP_INPUT_UART_FILE" "$TMP_EXPECTED_UART_FILE"
