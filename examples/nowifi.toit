import esp32 show adjust_real_time_clock
import ds3231 show Ds3231

// Only RTC is available, no wifi. The DS3231 can be off 1 min/year
// but for many applications this is OK.
// If there is Wifi, even occasionally
// you should check the "ntp-plus-rtc.toit" example.

// Wiring for the DFRobot FireBeetle 2 ESP32-C6. See the README for other boards.
SDA-PIN ::= 19
SCL-PIN ::= 20

rtc ::= Ds3231 --sda=SDA-PIN --scl=SCL-PIN

main:
  // set-timezone "EET-2EEST,M3.5.0/3,M10.5.0/4"
  task:: update-system-time
  sleep --ms=1_000 // wait a while, so the main-job finds correct time
  task:: main-job


main-job: // Does not return, and should typically called inside a task.
  while true:
    /** Works OK without internet. Of course the DS3231 must have correct
    time, and a good CR2032 coin cell. */
    print "The time is $Time.now" // Or Time.now.local
    sleep --ms=5_000

update-system-time: // Does not return, and should typically called inside a task.
  while true:
    adjustment := rtc.get
    // The Ds3231 crystal is way more accurate than the crystal on the ESP32 board
    // and also is temperature compensated.
    adjust_real_time_clock adjustment
    print "Got system time from RTC : adjustment=$adjustment"
    //else:
    //  print "Cannot get the RTC time : $result.error"
    sleep (Duration --h=1)
