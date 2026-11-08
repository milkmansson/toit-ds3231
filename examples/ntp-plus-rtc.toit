import esp32 show adjust_real_time_clock
import ds3231 show Ds3231
import ntp

/*
Scenario:
We have both wifi and DS3231 and we want the RTC
for the periods the WIFI is unavailable.

If the DS3231 is the only device on the i2c bus, the constructor below creates
the bus. Leave out --vcc and --gnd if the module is wired to real VCC and GND pins.
They can be GPIO pins (the module needs only about 4mA). That is useful for easy
cabling, and for battery powered projects (the ESP32 sleep turns off the DS3231):

  rtc ::= Ds3231 --sda=SDA-PIN --scl=SCL-PIN --vcc=33 --gnd=32

If the bus is shared between more than one i2c device, create the bus
and pass the device:

  bus := i2c.Bus --sda=SDA-PIN --scl=SCL-PIN
  rtc := Ds3231 (bus.device Ds3231.I2C-ADDRESS)

Read the board's documentation on the pins you can use. Strapping and special
purpose pins should be avoided.
*/

// Wiring for the DFRobot FireBeetle 2 ESP32-C6. See the README for other boards.
SDA-PIN ::= 19
SCL-PIN ::= 20

rtc ::= Ds3231 --sda=SDA-PIN --scl=SCL-PIN

main:
  task:: update-time // This task is doing the time sync
  task:: check-time-sync // for debugging
  //task:: check-get-set-accuracy // for debugging
  //task:: my-project

// This task is using the most appropriate time source :
// If internet is working, it uses NTP (and updates the RTC),
// and when NTP is not available, it uses DS3231 as a backup
update-time:
  last-ntp-time/Time? := null
  // The RTC is available before Wifi+NTP and sets the time first. It has no
  // valid time after a power loss (oscillator stopped), then we wait for NTP.
  if rtc.oscillator-stopped:
    print "The RTC lost its time, waiting for NTP"
  else:
    error := catch:
      adjustment := rtc.get
      adjust_real_time_clock adjustment
      print "Got system time from RTC : $(Time.now + adjustment)"
    if error: print "Cannot use the RTC time : $error"
  while true:
    result := ntp.synchronize // --max-rtt=(Duration --ms=500)  --server="pool.ntp.org"
    if result:
      if last-ntp-time != null:
        if result.accuracy > (Duration --ms=100):
          print "The accuracy is bad, bypassing the measurement"
          sleep (Duration --m=1)
          continue
      last-ntp-time = Time.now + result.adjustment
      rtc.set result.adjustment
      rtc.clear-oscillator-stopped
      adjust_real_time_clock result.adjustment // The time will be corrected gradually
      print "Setting the RTC time using the NTP time"
      print "NTP sync done adjustment=$result.adjustment acc=$result.accuracy"
      sleep (Duration --m=30) // sync again after 30 min
    else:
      print "NTP synchronization failed" // comment out if the wifi is intermittent
      sleep (Duration --m=1) // we will try again in 1 min.

check-time-sync: // for debugging purposes
  sleep --ms=5000
  print "\n\n\nDo not use this for working projects, tries to demonstrate the system clock drift(significant) and the DS3231 clock drift, which is minimal and hardly measurable with this test, unless you leave it running for at least a day.\n\n\n"
  while true:
    ntp-result := ntp.synchronize // --server="your local server IP but usually not needed"
    if ntp-result:
      print "[TEST-START] NTP-time - System-time : $ntp-result.adjustment accuracy=$ntp-result.accuracy"
    adjustment/Duration? := null
    error := catch: adjustment = rtc.get
    if error:
      print "[TEST      ] Cannot read the RTC : $error"
    else:
      print "[TEST      ] RTC-time - System-time : $adjustment. Possible RTC drift : $(rtc.expected-drift --from-time=Time.now)"
      if ntp-result:
        print "[TEST-END  ] NTP-time - RTC-time    : $(ntp-result.adjustment - adjustment)"
    sleep --ms=30_000

check-get-set-accuracy:
  sleep --ms=5000
  print "\n\n\nDo not use this for working projects, it sets and gets back the time from the RTC to demonstrate how accurate the set/get functions are.\n\n\n"
  while true:
    print "We set the RTC time $Time.now"
    rtc.set (Duration 0)
    sleep --ms=1500
    print "We get it again"
    adjustment := rtc.get
    print "Difference is $adjustment"
    sleep --ms=4500
