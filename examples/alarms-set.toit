import ds3231 show *

/*
Scenario:

We have an RTC and we wish to program an alarm.

// rtc ::= Ds3231 --scl=7 --sda=6 --vcc=10 --gnd=3 /* esp32-c3 core with GPIO as vcc and gnd */
// rtc := Ds3231 --sda=25 --scl=26 --vcc=33 --gnd=32 /* Lolin32 lite */
// rtc := Ds3231 --sda=33 --scl=32 --vcc=25 --gnd=26 /* ESP32 Devkit all versions */
// rtc := Ds3231 --sda=35 --scl=36 --vcc=37 --gnd=38 /* S3 devkitC abudance of pins here */

*/

rtc ::= Ds3231 --scl=20 --sda=19 /* esp32-c6 DFrobot Beetle */

main:
  alarm1 := rtc.get-alarm 1
  alarm2 := rtc.get-alarm 2
  print "Alarm 1 was: $alarm1 ($(alarm1.stringify --debug))"
  print "Alarm 2 was: $alarm2 ($(alarm2.stringify --debug))"

  // Create blank alarm object - essentially every second:
  blank := AlarmSpec
  print "Blank alarm is: $blank ($(blank.stringify --debug))"

  // Create hourly alarm object - every time the minute gets to '00':
  hourly := AlarmSpec.every-hour --minute=00
  print "Hourly alarm is: $hourly ($(hourly.stringify --debug))"

  // Create daily alarm object - at 12:00 every day:
  daily := AlarmSpec.every-day --hour=12 --minute=00
  print "Daily alarm is: $daily ($(daily.stringify --debug))"

  rtc.set-alarm 1 blank
  alarm1 = rtc.get-alarm 1
  print "Alarm 1 is now: $alarm1"


  print "Alarm 1: $alarm1"
  print "Alarm 2: $alarm2"
