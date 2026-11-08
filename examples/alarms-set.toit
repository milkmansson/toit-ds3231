import ds3231 show *

/*
Scenario:

We have an RTC and we wish to program an alarm.
*/

// Wiring for the DFRobot FireBeetle 2 ESP32-C6. See the README for other boards.
SDA-PIN ::= 19
SCL-PIN ::= 20

rtc ::= Ds3231 --sda=SDA-PIN --scl=SCL-PIN

main:
  print

  // Show some ways of creating the alarms

  // Create blank alarm object - essentially every second:
  blank := AlarmSpec
  print "Blank alarm is: $blank ($(blank.stringify --debug))"

  // Create minutely alarm object - every time the seconds get to '30':
  minutely := AlarmSpec.every-minute --seconds=30
  print "Minutely alarm is: $minutely ($(minutely.stringify --debug))"

  // Create hourly alarm object - every time the minute gets to '00':
  hourly := AlarmSpec.every-hour --minute=00
  print "Hourly alarm is: $hourly ($(hourly.stringify --debug))"

  // Create daily alarm object - at 12:00 every day:
  daily := AlarmSpec.every-day --hour=12 --minute=00
  print "Daily alarm is: $daily ($(daily.stringify --debug))"

  // Current configuration:
  alarm1 := rtc.get-alarm 1
  alarm2 := rtc.get-alarm 2
  print "Alarm 1 is: $alarm1"
  print "Alarm 2 is: $alarm2"

  // Set alarm 1 to the minutely alarm, and alarm 2 to the blank alarm:
  rtc.set-alarm 1 minutely
  rtc.set-alarm 2 blank
  print "Alarm 1 now set to: $minutely and Alarm 2 now set to: $blank"

  // Set SQW Pin to Interrupt output:
  rtc.set-sqw-as-interrupt true

