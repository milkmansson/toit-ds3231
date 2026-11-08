import ds3231 show Ds3231

/*
Scenario:

We have an RTC and we wish to see what alarms are programmed with it.
*/

// Wiring for the DFRobot FireBeetle 2 ESP32-C6. See the README for other boards.
SDA-PIN ::= 19
SCL-PIN ::= 20

rtc ::= Ds3231 --sda=SDA-PIN --scl=SCL-PIN

main:
  alarm1 := rtc.get-alarm 1
  alarm2 := rtc.get-alarm 2

  print "Alarm 1: $alarm1"
  print "Alarm 2: $alarm2"
