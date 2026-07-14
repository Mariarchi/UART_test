#!/bin/bash
# Первый параметр $1 - это температура, $2 - это номер первой подключённой платы, $3 - это номер второй подключённой платы

set -euo pipefail # ключ -e завершает работу, если есть ошибка; -u рассматривает не объявленные переменные как ошибку; -o pipefail если хоть один конвейер упадёт, вся цепочка вернёт ошибку
declare -r TESTS_BIN_FILES_PATH="./generated_test"
declare -ri TEST_FILE_SIZE=2048 # размер тестового файла в байтах
declare -r AMBIENT_TEMPERATURE="${1:-temperature_argument_not_set}" # Окружающая температура
declare -r UART_TEST_LOG_FILE="UART_test_$AMBIENT_TEMPERATURE.tsv" # далее добавляем информацию так:  | tee -a "$UART_TEST_LOG_FILE"
declare -r TEMP_INPUT_UART_FILE="temp_UART_output.bin"
declare -Ar TESTED_WORDS=(
    [cs5]=$((2#10101))
    [cs6]=$((2#101010))
    [cs7]=$((2#1010101))
    [cs8]=$((2#10101010))
)
declare -r OPEN_PORT_TIME="0.2"
declare -r CLOSE_PORT_TIME="0.5"
# Доступные параметры для CH340G
declare -ri baud_rates=(50 1500000)
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
declare -r flow_control="-parenb" # отключено
declare -r parity_none="-parenb"
# Проверка чётности / нечётности у меня не получилась, поэтому следующие переменные можно проигнорировать:
# declare parity_even="parenb -parodd"
# declare parity_odd="parenb parodd"



# Проверяем, сколько обнаружено USB - UART преобразователей
find /dev/ -maxdepth 1 -name "ttyUSB*"

declare -a paths_USB_UART
mapfile -t paths_USB_UART < <(find /dev/ -maxdepth 1 -name "ttyUSB*")
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


# Опробование
if [ "$COUNT_USB_UART" -eq 1 ]; then
    # Проверка преобразователя "Самого на себя". Джампер соединяет tx с rx
    echo -e "\nПетлевой тест. Опробование:"
    echo "Устанавливаю настройки для $path_USB_UART_1: raw ${baud_rates[1]} ${character_size_stty[3]} ${stop_bits_stty[0]} ${parity_none[0]} -echo"
    stty -F "$path_USB_UART_1" raw "${baud_rates[1]}" "${character_size_stty[3]}" "${stop_bits_stty[0]}" "${parity_none[0]}" -echo
    
    cat "$path_USB_UART_1" > "$TEMP_INPUT_UART_FILE" & READER_PID=$! # Запускаем фоновое чтение с порта в лог-файл, запоминаем ID процесса чтения
    sleep "$OPEN_PORT_TIME" # Даем порту время открыться
    echo "Передаю данные: ${TESTED_WORDS[cs5]}"
    echo -n "${TESTED_WORDS[cs5]}" > "$path_USB_UART_2"
    sleep "$CLOSE_PORT_TIME" # Ждем завершения передачи
    kill $READER_PID # Убиваем фоновый процесс чтения
    printf "Полученные данные: %s \n" "$(cat "$TEMP_INPUT_UART_FILE")"

    if grep -q "${TESTED_WORDS[cs5]}" "$TEMP_INPUT_UART_FILE"; then
        echo "УСПЕШНАЯ ПЕРЕДАЧА ДАННЫХ"
    else
        echo "ОШИБКА ПЕРЕДАЧИ ДАННЫХ. ТЕСТ НЕ ПРОШЁЛ ОПРОБОВАНИЕ"
        exit 1
    fi
else
    # Проверка преобразователя одного с другим
    echo "Устанавливаю настройки для $$path_USB_UART_1: raw ${baud_rates[1]} ${character_size_stty[3]} ${stop_bits_stty[0]} ${parity_none[0]} -echo"
    stty -F "$path_USB_UART_1" raw "${baud_rates[1]}" "${character_size_stty[3]}" "${stop_bits_stty[0]}" "${parity_none[0]}" -echo
    echo "Устанавливаю настройки для $path_USB_UART_2: raw ${baud_rates[1]} ${character_size_stty[3]} ${stop_bits_stty[0]} ${parity_none[0]} -echo"
    stty -F "$path_USB_UART_2" raw "${baud_rates[1]}" "${character_size_stty[3]}" "${stop_bits_stty[0]}" "${parity_none[0]}" -echo
    
    echo -e "\nПерекрёстный тест в прямом направлении. Опробование:"
    cat "$path_USB_UART_1" > "$TEMP_INPUT_UART_FILE" & READER_PID=$! # Запускаем фоновое чтение с порта в лог-файл, запоминаем ID процесса чтения
    sleep "$OPEN_PORT_TIME" # Даем порту время открыться
    echo "Передаю данные: ${TESTED_WORDS[cs5]}"
    echo -n "${TESTED_WORDS[cs5]}" > "$path_USB_UART_2"
    sleep "$CLOSE_PORT_TIME" # Ждем завершения передачи
    kill $READER_PID # Убиваем фоновый процесс чтения
    printf "Полученные данные: %s \n" "$(cat UART_output.log)"

    if grep -q "${TESTED_WORDS[cs5]}" "$TEMP_INPUT_UART_FILE"; then
        echo "УСПЕШНАЯ ПЕРЕДАЧА ДАННЫХ"
    else
        echo "ОШИБКА ПЕРЕДАЧИ ДАННЫХ. ТЕСТ НЕ ПРОШЁЛ ОПРОБОВАНИЕ"
        exit 1
    fi

    echo -e "\nПерекрёстный тест в обратном направлении. Опробование:"
    cat "$path_USB_UART_2" > "$TEMP_INPUT_UART_FILE" & READER_PID=$! # Запускаем фоновое чтение с порта в лог-файл, запоминаем ID процесса чтения
    sleep "$OPEN_PORT_TIME" # Даем порту время открыться
    echo "Передаю данные: ${TESTED_WORDS[cs5]}"
    echo -n "${TESTED_WORDS[cs5]}" > "$path_USB_UART_1"
    sleep "$CLOSE_PORT_TIME" # Ждем завершения передачи
    kill $READER_PID # Убиваем фоновый процесс чтения
    printf "Полученные данные: %s \n" "$(cat "$TEMP_INPUT_UART_FILE")"

    if grep -q "${TESTED_WORDS[cs5]}" "$TEMP_INPUT_UART_FILE"; then
        echo "УСПЕШНАЯ ПЕРЕДАЧА ДАННЫХ"
    else
        echo "ОШИБКА ПЕРЕДАЧИ ДАННЫХ. ТЕСТ НЕ ПРОШЁЛ ОПРОБОВАНИЕ"
        exit 1
    fi
fi



# Проверяем, есть ли у нас сгенерированные тесты, если нет - генерируем их
if ! [ -d "$TESTS_BIN_FILES_PATH" ]; then
    echo -e "\nПапка $TESTS_BIN_FILES_PATH не существует. Создаю её:"
    mkdir -p "$TESTS_BIN_FILES_PATH"
fi
if ! [ -s "$TESTS_BIN_FILES_PATH/test_cs5.bin" ]; then
    echo "Файл для теста CS5 не существует или он пустой. Генерирую тест"
    od -An -v -tu1 -N $TEST_FILE_SIZE /dev/urandom | awk '{for(i=1;i<=NF;i++) printf "%c", $i%32}' > "$TESTS_BIN_FILES_PATH/test_cs5.bin"
fi
if ! [ -s "$TESTS_BIN_FILES_PATH/test_cs6.bin" ]; then
    echo "Файл для теста CS6 не существует или он пустой. Генерирую тест"
    od -An -v -tu1 -N $TEST_FILE_SIZE /dev/urandom | awk '{for(i=1;i<=NF;i++) printf "%c", $i%64}' > "$TESTS_BIN_FILES_PATH/test_cs6.bin"
fi
if ! [ -s "$TESTS_BIN_FILES_PATH/test_cs7.bin" ]; then
    echo "Файл для теста CS7 не существует или он пустой. Генерирую тест"
    od -An -v -tu1 -N $TEST_FILE_SIZE /dev/urandom | awk '{for(i=1;i<=NF;i++) printf "%c", $i%128}' > "$TESTS_BIN_FILES_PATH/test_cs7.bin"
fi
if ! [ -s "$TESTS_BIN_FILES_PATH/test_cs8.bin" ]; then
    echo "Файл для теста CS8 не существует или он пустой. Генерирую тест"
    dd if=/dev/urandom of="$TESTS_BIN_FILES_PATH/test_cs8.bin" bs=1 count=$TEST_FILE_SIZE status=none
fi



# Проведение тестов
declare -r BOARD_NUMBER_1="${2:-X}" # Номер 1-й платы. Если $2 задан и не пустой → берётся $2; если не задан или пустой → подставляется "X"
declare -r BOARD_NUMBER_2="${3:-X}" # Номер 2-й платы

printf "" > "$UART_TEST_LOG_FILE" # Стираем старую информацию из лог-файла
printf "\n%s\n" "Запускаем тесты с различными комбинациями параметров UART"
printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
    "Номер 1-й платы" \
    "Номер 2-й платы" \
    "Температура окружающей среды" \
    "Размер передаваемой информации"  \
    "Baud rate" \
    "Data bits" \
    "Stop bits" \
    "Parity" \
    "Flow control" \
    "Итог" \
    >> "$UART_TEST_LOG_FILE"

for baud_rate in "${baud_rates[@]}"; do
    # echo "$baud_rate"

    for stop_bits_key in "${!stop_bits[@]}"; do
        # echo "$stop_bits_key value=${stop_bits[$stop_bits_key]}"

        for character_size_key in "${!character_sizes[@]}"; do
            # echo "$character_size_key value=${character_sizes[$character_size_key]}"
            # echo "${TESTED_WORDS[$character_size_key]}"

            stty -F "$path_USB_UART_1" raw "$baud_rate" "$character_size_key" "$parity_none" "$stop_bits_key" "$flow_control" -echo
            stty -F "$path_USB_UART_2" raw "$baud_rate" "$character_size_key" "$parity_none" "$stop_bits_key" "$flow_control" -echo

            cat "$path_USB_UART_1" > "$TEMP_INPUT_UART_FILE" & READER_PID=$! # на 1-м устройстве слушаем
            sleep "$OPEN_PORT_TIME" # Даем порту время открыться
            echo -n "${TESTED_WORDS[$character_size_key]}" > "$path_USB_UART_2" # на 2-е устройство передаём
            sleep "$CLOSE_PORT_TIME" # Ждем завершения передачи
            kill $READER_PID # Убиваем фоновый процесс чтения

            declare test_result
            if grep -q "${TESTED_WORDS[$character_size_key]}" "$TEMP_INPUT_UART_FILE"; then
                test_result="PASS"
            else
                test_result="FAILED"
            fi

            printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
                "№ $BOARD_NUMBER_1" \
                "№ $BOARD_NUMBER_2" \
                "$AMBIENT_TEMPERATURE °C" \
                "Слово"  \
                "$baud_rate бод" \
                "${character_sizes[$character_size_key]} бит" \
                "${stop_bits[$stop_bits_key]} бит(-а)" \
                "Без проверки чётности" \
                "Отключено" \
                "$test_result" \
                >> "$UART_TEST_LOG_FILE"
        done
    done
done




rm "$TEMP_INPUT_UART_FILE"