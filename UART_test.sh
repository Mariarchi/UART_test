#!/bin/bash
# Скрипт на входе принимает следующие параметры. Они не обязательны, но допускается вводить только 1, 2, 3 и 5 параметров, иначе скрипт выкинет ошибку.
# $1 - температура, $2 - номер первой подключённой платы, $3 - номер второй подключённой платы; $4 - путь для stty для 1-й платы (ttyUSB0, ttyACM1 и пр.); $5 - путь для stty для 2-й платы

set -euo pipefail # ключ -e завершает работу, если есть ошибка; -u рассматривает не объявленные переменные как ошибку; -o pipefail если хоть один конвейер упадёт, вся цепочка вернёт ошибку
declare -r TESTS_BIN_FILES_PATH="./generated_test"
declare -r AMBIENT_TEMPERATURE="${1:-temperature_argument_not_set}" # Окружающая температура
declare -r UART_TEST_LOG_FILE="UART_test_$AMBIENT_TEMPERATURE.tsv"
declare -r TMP_INPUT_UART_FILE="temp_UART_output.bin"
declare -r TMP_EXPECTED_UART_FILE="temp_UART_expected.bin"
declare -rA TESTED_WORDS=(
    [cs5]=$((2#10101))
    [cs6]=$((2#101010))
    [cs7]=$((2#1010101))
    [cs8]=$((2#10101010))
)
declare -r OPEN_PORT_TIME="0.2"
declare -r READ_TIMEOUT="60"

# Доступные параметры для устройства UART
# Скорость и соответствующий ему размер тестового файла в байтах. При такой конфигурации тест будет длиться примерно 47 минут
declare -rA baud_rates_AND_test_file_size=(
    [1200]=1024
    [9600]=8192
    [38400]=65536
    [115200]=131072
    [921600]=262144
)
declare -ra character_size_stty=(cs5 cs6 cs7 cs8)
declare -rA character_sizes=(
    [cs5]=5
    [cs6]=6
    [cs7]=7
    [cs8]=8
)
declare -ar stop_bits_stty=("-cstopb" "cstopb")
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
# 2>/dev/null - перенаправляем поток с ошибками в "никуда"
mapfile -t paths_USB_UART < <(find /dev/ -maxdepth 1 \( -name 'ttyUSB*' -o -name 'ttyACM*' \) 2>/dev/null) # преобразователь определяется в системе иногда как ttyUSB, а иногда как ttyACM
declare -ri COUNT_USB_UART=${#paths_USB_UART[@]}
declare path_USB_UART_1 path_USB_UART_2

if [ $# -le 3 ]; then
    if [ "$COUNT_USB_UART" -eq 0 ]; then
        echo "Преобразователей USB - UART не обнаружено. Прекращаю свою работу"
        exit 1
    elif [ "$COUNT_USB_UART" -gt 2 ]; then
        echo "Преобразователей USB - UART более 2-х штук. Прекращаю свою работу"
        exit 1
    else
        echo "Количество преобразователей: $COUNT_USB_UART"
    fi

    if [ "$COUNT_USB_UART" -eq 1 ]; then
        path_USB_UART_1="${paths_USB_UART[0]}"
        path_USB_UART_2="${paths_USB_UART[0]}"
    else
        path_USB_UART_1="${paths_USB_UART[0]}"
        path_USB_UART_2="${paths_USB_UART[1]}"
    fi
elif [ $# -eq 5 ]; then
    path_USB_UART_1="/dev/$4"
    path_USB_UART_2="/dev/$5"

    if [[ ! -e "$path_USB_UART_1" ]]; then
        echo "Ошибка: $path_USB_UART_1 не найден"
        exit 1
    fi
    if [[ ! -e "$path_USB_UART_2" ]]; then
        echo "Ошибка: $path_USB_UART_2 не найден"
        exit 1
    fi
else
    echo "Количество параметров введено неверно, их должно быть от 0 до 3 либо 5. Прекращаю свою работу"
    exit 1
fi



transmit_and_receive() {
    local receive_port=$1
    local transmit_port=$2
    local expected_file=$3
    local expected_size
    local reader_pid

    expected_size=$(wc -c < "$expected_file")
    : > "$TMP_INPUT_UART_FILE" # очищаем содержимое файла, или создаём пустой заново

    # dd - побайтово копирует данные; if - input file; of - output file; bs - block size; count - кол-во ситаемой информации; status=none - не выводить статистику; & - запустить чтение в фоне
    timeout "$READ_TIMEOUT" dd if="$receive_port" of="$TMP_INPUT_UART_FILE" bs=1 count="$expected_size" status=none &
    reader_pid=$! # сохраняем PID (идентификатор процесса) последней запущенной фоновой команды (&)
    sleep "$OPEN_PORT_TIME" # Даем порту время открыться
    cat "$expected_file" > "$transmit_port" # отправляем тестовую в UART
    wait "$reader_pid"
}

# проверяем, надо ли генерировать бинарные файлы с тестами
test_file_needs_generation() {
    local test_file=$1
    local expected_size=$2
    local actual_size

    # если файл не обнаружен, возвращаем 0
    if ! [ -f "$test_file" ]; then
        return 0
    fi

    actual_size=$(wc -c < "$test_file") # подсчитываем количество байтов
    [ "$actual_size" -ne "$expected_size" ] # если размер файла в переменной $actual_size не равен ожидаемому размеру, возвращаем 0, иначе возвращаем 1
}

get_test_file_path() {
    local baud_rate=$1
    local character_size_key=$2

    printf "%s/test_%s_%s.bin" "$TESTS_BIN_FILES_PATH" "$baud_rate" "$character_size_key"
}

generate_test_file() {
    local character_size_key=$1
    local test_file_size=$2
    local test_file=$3

    case "$character_size_key" in
        cs5)
            od -An -v -tu1 -N "$test_file_size" /dev/urandom | awk '{for(i=1;i<=NF;i++) printf "%c", $i%32}' > "$test_file"
            ;;
        cs6)
            od -An -v -tu1 -N "$test_file_size" /dev/urandom | awk '{for(i=1;i<=NF;i++) printf "%c", $i%64}' > "$test_file"
            ;;
        cs7)
            od -An -v -tu1 -N "$test_file_size" /dev/urandom | awk '{for(i=1;i<=NF;i++) printf "%c", $i%128}' > "$test_file"
            ;;
        cs8)
            dd if=/dev/urandom of="$test_file" bs=1 count="$test_file_size" status=none
            ;;
    esac
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
for baud_rate in "${!baud_rates_AND_test_file_size[@]}"; do test_file_size=${baud_rates_AND_test_file_size[$baud_rate]}

    for character_size_key in "${!character_sizes[@]}"; do
        test_file=$(get_test_file_path "$baud_rate" "$character_size_key")

        if test_file_needs_generation "$test_file" "$test_file_size"; then
            echo "Файл $test_file не существует или имеет неправильный размер. Генерирую тест"
            generate_test_file "$character_size_key" "$test_file_size" "$test_file"
        fi
    done
done



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
for baud_rate in "${!baud_rates_AND_test_file_size[@]}"; do test_file_size=${baud_rates_AND_test_file_size[$baud_rate]}
    for stop_bits_key in "${!stop_bits[@]}"; do
        for character_size_key in "${!character_sizes[@]}"; do
            test_file=$(get_test_file_path "$baud_rate" "$character_size_key")

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
                    read -r -a parity_options <<< "${parity_modes[$parity_mode_key]}" # превращаем строку parity_modes в массив, для того, чтобы потом безопасно передать аргументы в stty

                    stty -F "$path_USB_UART_1" raw "$baud_rate" "$character_size_key" "${parity_options[@]}" "$stop_bits_key" "$flow_control" -echo inpck -parmrk ignpar
                    stty -F "$path_USB_UART_2" raw "$baud_rate" "$character_size_key" "${parity_options[@]}" "$stop_bits_key" "$flow_control" -echo inpck -parmrk ignpar

                    if [ "$test_payload_type" = "file" ]; then
                        expected_file=$test_text_sequence # прописываем путь к бинарному файлу с тестами
                    else
                        printf "%s" "$test_text_sequence" > "$TMP_EXPECTED_UART_FILE" # записываем тестовую бинарную последовательность в TMP_EXPECTED_UART_FILE
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
                run_test "$path_USB_UART_1" "$path_USB_UART_2" "$BOARD_NAME_1" "$BOARD_NAME_2" "$test_file" "file" "Текст $test_file_size байт"
                run_test "$path_USB_UART_2" "$path_USB_UART_1" "$BOARD_NAME_2" "$BOARD_NAME_1" "$test_file" "file" "Текст $test_file_size байт"

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
