import ds3231 show Ds3231

/*
Scenario:

We have an RTC and we wish to see what alarms are programmed with it.

// rtc ::= Ds3231 --scl=7 --sda=6 --vcc=10 --gnd=3 /* esp32-c3 core with GPIO as vcc and gnd */
// rtc := Ds3231 --sda=25 --scl=26 --vcc=33 --gnd=32 /* Lolin32 lite */
// rtc := Ds3231 --sda=33 --scl=32 --vcc=25 --gnd=26 /* ESP32 Devkit all versions */
// rtc := Ds3231 --sda=35 --scl=36 --vcc=37 --gnd=38 /* S3 devkitC abudance of pins here */

*/

rtc ::= Ds3231 --scl=20 --sda=19 /* esp32-c6 DFrobot Beetle */

main:
  alarm1 := rtc.get-alarm 1
  alarm2 := rtc.get-alarm 2

  print "Alarm 1: $alarm1"
  print "Alarm 2: $alarm2"
