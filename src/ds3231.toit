import gpio
import i2c
import serial

/**
Driver for the DS3231 Real Time Clock.
*/
class Ds3231:
  /** The i2c address of the DS3231. It is fixed and cannot be changed. */
  static I2C-ADDRESS/int ::= 0x68

  static REG-START_/int ::= 0x00  // The first time (seconds) register is at location 0x00.
  static REG-NUM_/int ::= 7       // We read 7 consecutive registers, up to the (2-digit) year.

  static REG-CONTROL_/int ::= 0x0E
  static REG-STATUS_/int ::= 0x0F
  static REG-AGING_/int ::= 0x10
  static REG-TEMPERATURE_/int ::= 0x11

  // Bits of $REG-CONTROL_.
  static CONV-BIT_/int ::= 0b0010_0000   // Start a temperature conversion.
  static BBSQW-BIT_/int ::= 0b0100_0000  // Battery-backed square wave.
  static INTCN-BIT_/int ::= 0b0000_0100  // SQW pin signals alarms instead of a square wave.
  static SQW-MASK_/int ::= 0b0001_1100   // RS2, RS1 and INTCN.

  // Bits of $REG-STATUS_.
  static OSF-BIT_/int ::= 0b1000_0000  // Oscillator stopped.
  static BSY-BIT_/int ::= 0b0000_0100  // Temperature conversion in progress.

  // Support for Alarms:
  static REG-ALARM-1-START_/int ::= 0x07  // Alarm 1 has 4 bytes.
  static REG-ALARM-2-START_/int ::= 0x0B  // Alarm 2 has 3 bytes (drops seconds component).
  // Masks for $REG-STATUS_ (alarm tripped) and $REG-CONTROL_ (alarm enabled).
  static ALARM-1-BIT_/int ::= 0b0000_0001
  static ALARM-2-BIT_/int ::= 0b0000_0010

  /** The oldest year that $get and $set accept, unless told otherwise. */
  static MIN-VALID-YEAR_/int ::= 2025

  /**
  The register access used to talk to the chip.

  Use it directly if the library does not implement a function.
  In that case you may also consider $set-value-with-mask.
  */
  registers/serial.Registers := ?

  /**
  The I2C bus.

  Null, if not allocated by this class.
  Kept public in case you want to use another i2c device on the same bus,
    for example the AT24C32 EEPROM (on the blue DS3231 boards).
  */
  bus/i2c.Bus? := null
  /** The vcc pin, if specified. */
  vcc_/gpio.Pin? := null
  /** The gnd pin, if specified. */
  gnd_/gpio.Pin? := null

  /**
  Creates a Ds3231 instance, given a $serial.Device object.
  */
  constructor device/serial.Device:
    registers = device.registers

  /**
  Variant of $(constructor device).

  Convenience function to build an i2c bus and device during construction. The
    $sda and $scl are GPIO numbers.

  If given, $vcc/$gnd are initialized as output pins with the corresponding levels.
    This simplifies the Ds3231 cabling, and allows to save power when the ESP32 goes
    to sleep.
  */
  constructor
      --sda/int
      --scl/int
      --vcc/int? = null
      --gnd/int? = null:
    local-bus/i2c.Bus? := null
    device/i2c.Device? := null
    try:
      // The vcc and gnd are the first to configure, to allow the module to
      // power up and communicate with i2c.
      if vcc and vcc >= 0:
        vcc_ = gpio.Pin vcc --output
        vcc_.set 1
      if gnd and gnd >= 0:
        gnd_ = gpio.Pin gnd --output
        gnd_.set 0
      if vcc_ or gnd_:
        // Give the DS3231 some time to power up.
        sleep --ms=5
      local-bus = i2c.Bus --sda=sda --scl=scl
      device = local-bus.device I2C-ADDRESS
    finally: | is-exception _ |
      if is-exception:
        if local-bus: local-bus.close
        if vcc_: vcc_.close
        if gnd_: gnd_.close
    bus = local-bus
    registers = device.registers

  /**
  Closes this driver.

  Releases the bus and pins that this driver allocated itself.
  */
  close -> none:
    if bus:
      bus.close
      bus = null
    if vcc_:
      vcc_.close
      vcc_ = null
    if gnd_:
      gnd_.close
      gnd_ = null

  /**
  Reads the time from the Ds3231 chip, and returns the adjustment.

  If $wait-sec-change is false the function returns immediately but can have a time
    error of up to 1 second.
  If $wait-sec-change is true (the default), this function can block up to 1 sec but
    the adjustment is accurate to about 1 ms. It throws "DS3231_NOT_TICKING" if the
    seconds do not change, which happens when the oscillator has stopped.
  Throws "DS3231_TIME_IS_INVALID" if the chip time is earlier than the year 2025,
    unless $allow-wrong-time is set. See $oscillator-stopped to find out if the
    chip has lost its time.
  */
  get -> Duration
      --wait-sec-change/bool = true
      --allow-wrong-time/bool = false:
    if wait-sec-change:
      start-us := Time.monotonic-us
      v := registers.read-u8 REG-START_
      while true:
        yield
        v1 := registers.read-u8 REG-START_
        if v != v1: break
        if Time.monotonic-us - start-us > 1_500_000: throw "DS3231_NOT_TICKING"
    // The time is read just when the seconds register (address 0x00)
    // goes to the next second.
    rtctime := get_
    adjustment := Time.now.to rtctime
    if not allow-wrong-time and rtctime.utc.year < MIN-VALID-YEAR_:
      throw "DS3231_TIME_IS_INVALID"
    return adjustment

  /**
  Sets the RTC time to Time.now+$adjustment.

  See $get for the meaning of $wait-sec-change and $allow-wrong-time. Setting the
    time does not clear the oscillator stopped flag. See $clear-oscillator-stopped.
  */
  set adjustment/Duration
      --wait-sec-change/bool=true
      --allow-wrong-time/bool=false -> none:
    adjustment += (Duration --us=2750)  // We compensate for the i2c and MCU delays.
    if not allow-wrong-time and (Time.now + adjustment).utc.year < MIN-VALID-YEAR_:
      throw "YEAR_LESS_THAN_2025"
    if wait-sec-change:  // Wait until the second changes (for better accuracy).
      s := (Time.now + adjustment).utc.s
      while true:
        yield  // Allow other tasks to run.
        if (Time.now + adjustment).utc.s != s: break
    set_ (Time.now + adjustment)

  get_ -> Time:
    buffer := registers.read-bytes REG-START_ REG-NUM_
    hour-byte := buffer[2]
    hour/int := ?
    if (hour-byte & 0b0100_0000) != 0:  // 12-hour mode.
      hour = (bcd2int_ (hour-byte & 0x1F)) % 12
      if (hour-byte & 0b0010_0000) != 0: hour += 12
    else:
      hour = bcd2int_ (hour-byte & 0x3F)
    // Bit 7 of the month register is the century bit.
    century := (buffer[5] & 0x80) != 0 ? 100 : 0
    return Time.utc
        --s=(bcd2int_ buffer[0])
        --m=(bcd2int_ buffer[1])
        --h=hour
        --day=(bcd2int_ buffer[4])
        --month=(bcd2int_ (buffer[5] & 0x1F))
        --year=(2000 + century + (bcd2int_ buffer[6]))

  set_ tm/Time -> none:
    u := tm.utc
    // Must be 7 fields, the same as the Ds3231 time keeping registers.
    t := [u.s, u.m, u.h, u.weekday, u.day, u.month, (u.year - 2000)]
    buffer := ByteArray REG-NUM_: int2bcd_ t[it]
    // Writing the seconds register resets the divider chain.
    // Without this a full second (1000ms) error often happens.
    registers.write-u8 REG-START_ 0
    registers.write-bytes REG-START_ buffer  // Writes the time.

  /**
  Sets the aging offset.

  Run the "offset-calculator.toit" app to calculate it.
  More info in the README.
  The new value will work after the next temp conversion.
  The $offset must satisfy -128 <= $offset <= 127.
  */
  set-aging-offset offset/int -> none:
    if not -128 <= offset <= 127: throw "INVALID_ARGUMENT"
    registers.write-i8 REG-AGING_ offset

  /**
  Reads the aging offset from the chip.

  When first powered it has the value of 0, but if set to a
    different value, it can retain this value as long as it is powered
    or battery backed.
  Useful with "offset-calculator.toit".
  */
  get-aging-offset -> int:
    return registers.read-i8 REG-AGING_

  /**
  Sets the frequency bits (and the INTCN bit) of the control register.

  Calls $set-value-with-mask with the right register and mask.
  */
  set-sqw_ value/int -> none:
    set-value-with-mask
        --register=REG-CONTROL_
        --mask=SQW-MASK_
        --value=value

  /**
  Sets some bits of the given $register.

  Uses the given $mask to select the bits that should be changed.
  No bits outside the $mask are changed.

  The given $value is applied unshifted (but masked).
  */
  set-value-with-mask --register/int --mask/int --value/int -> none:
    if not ((0 <= register <= 0x12) and (0 <= mask <= 255) and (0 <= value <= 255)):
      throw "PARAMETER_OUT_OF_BOUNDS"
    old-value/int := registers.read-u8 register
    registers.write-u8 register ((old-value & ~mask) | (value & mask))

  /** Equivalent with $enable-sqw-output --frequency=1. */
  enable-sqw-1hz -> none:
    enable-sqw-output --frequency=1

  /** Equivalent with $enable-sqw-output --frequency=1000. */
  enable-sqw-1kilohz -> none:
    enable-sqw-output --frequency=1000

  /** Equivalent with $enable-sqw-output --frequency=4000. */
  enable-sqw-4kilohz -> none:
    enable-sqw-output --frequency=4000

  /** Equivalent with $enable-sqw-output --frequency=8000. */
  enable-sqw-8kilohz -> none:
    enable-sqw-output --frequency=8000

  /**
  Enables the given $frequency on the sqw pin.

  The output is open-drain, and it requires pull-up (external or software).

  The $frequency must be one of 1, 1000, 4000, or 8000. The DS3231 generates
    1 Hz, 1.024 kHz, 4.096 kHz and 8.192 kHz respectively.
  This clears the INTCN bit, so the pin no longer signals alarms.
  */
  enable-sqw-output --frequency/int -> none:
    if frequency == 1: set-sqw_ 0b000_00_000  // RS2->0 RS1->0 INTCN->0.
    else if frequency == 1000: set-sqw_ 0b000_01_000
    else if frequency == 4000: set-sqw_ 0b000_10_000
    else if frequency == 8000: set-sqw_ 0b000_11_000
    else: throw "INVALID_FREQUENCY"

  /**
  Disables the square wave output on the sqw pin.

  Sets the INTCN bit, so the pin only signals alarms that are enabled
    with $enable-alarm.
  */
  disable-sqw -> none:
    set-sqw_ 0b000_11_100

  /**
  Enables the battery-backed sqw.

  The square wave is then also generated when the chip runs from the battery.
  */
  enable-battery-backed-sqw -> none:
    set-value-with-mask --register=REG-CONTROL_ --mask=BBSQW-BIT_ --value=BBSQW-BIT_

  /**
  Disables the battery-backed sqw.

  This is the default DS3231 setting.
  */
  disable-battery-backed-sqw -> none:
    set-value-with-mask --register=REG-CONTROL_ --mask=BBSQW-BIT_ --value=0

  /**
  Returns the temperature in celsius.

  The value has a resolution of 0.25°C, but the datasheet accuracy is
    only ±3°C. With the decimals you can find if the temp is going up or down.
  */
  get-temperature -> float:
    // (4*temp) is stored as 10-bit 2-complement number.
    // buf[0] the sign + 7 most significant bits.
    // buf[1] bits 7 and 6 represent the decimal part, the other bits are ignored.
    buf := registers.read-bytes REG-TEMPERATURE_ 2
    temp := (buf[0] << 2) | (buf[1] >> 6)
    if (temp & (1 << 9)) != 0:  // The 10-bit number is negative.
      temp -= (1 << 10)
    return temp / 4.0

  /**
  Forces a temperature conversion.

  Returns when the operation is finished. Usually not needed (happens
    automatically every 64sec), only if you use your DS3231 as a thermometer.
  Throws "TIMEOUT_WAITING_CONV" if the conversion does not finish within 300 ms.
  */
  force-temp-conversion -> none:
    // A conversion that is already running is waited for, instead of restarted.
    if ((registers.read-u8 REG-STATUS_) & BSY-BIT_) == 0:
      set-value-with-mask --register=REG-CONTROL_ --mask=CONV-BIT_ --value=CONV-BIT_
    30.repeat:
      busy := (registers.read-u8 REG-STATUS_) & BSY-BIT_
      converting := (registers.read-u8 REG-CONTROL_) & CONV-BIT_
      if busy == 0 and converting == 0: return
      sleep --ms=10
    throw "TIMEOUT_WAITING_CONV"

  /**
  Returns the expected drift since the given $from-time.

  The drift is calculated by assuming a 2ppm error (unless you set a different $ppm)
    since the last time the clock is set. The drift is usually smaller, and in some
    cases (high temperature deviations) can be greater. With the aging offset calibrated
    and not very high temperature deviations, this can be significantly lower.
  */
  expected-drift --from-time/Time --ppm/num=2 -> Duration:
    return (from-time.to Time.now) * (ppm / 1e6)

  /** Seconds, minutes, hours etc. are stored in the DS3231 registers as BCD. */
  static int2bcd_ x/int -> int:
    return (x / 10) * 16 + (x % 10)

  static bcd2int_ x/int -> int:
    return (x / 16) * 10 + (x % 16)

  /**
  Returns true if the oscillator has stopped since the flag was last cleared.

  This flag is set when the oscillator stops or was stopped, including when the
    coin cell was insufficient to maintain operation during a power loss. It is
    only cleared by calling $clear-oscillator-stopped.

  Check this on boot to determine whether the RTC time is still valid. If true,
    the time should be considered invalid and resynced from NTP or another
    source.
  */
  oscillator-stopped -> bool:
    return ((registers.read-u8 REG-STATUS_) & OSF-BIT_) != 0

  /**
  Clears the oscillator stopped flag.

  Call this after handling a stopped-oscillator condition, typically after
    resyncing the time from NTP or another source. If not cleared,
    $oscillator-stopped will continue to return true even after the oscillator
    has been running normally.
  */
  clear-oscillator-stopped -> none:
    set-value-with-mask --register=REG-STATUS_ --mask=OSF-BIT_ --value=0

  /**
  Enables or disables the hardware alarm $alarm-num (1 or 2) depending on $on.

  Alarm interrupts are only signaled on the sqw pin when $set-sqw-as-interrupt
    is enabled.
  */
  enable-alarm alarm-num/int on/bool -> none:
    mask := alarm-bit_ alarm-num
    set-value-with-mask --register=REG-CONTROL_ --mask=mask --value=(on ? mask : 0)

  /**
  Sets the sqw pin as interrupt for alarms, if $on is true.

  When false, the pin outputs the square wave configured with $enable-sqw-output.
  */
  set-sqw-as-interrupt on/bool -> none:
    set-value-with-mask --register=REG-CONTROL_ --mask=INTCN-BIT_ --value=(on ? INTCN-BIT_ : 0)

  /**
  Gets the hardware alarm $alarm-num (1 or 2) as an $AlarmSpec.
  */
  get-alarm alarm-num/int -> AlarmSpec:
    alarm-bit_ alarm-num
    if alarm-num == 1:
      return AlarmSpec.from-byte-array (registers.read-bytes REG-ALARM-1-START_ 4)
    return AlarmSpec.from-byte-array (registers.read-bytes REG-ALARM-2-START_ 3)

  /**
  Sets the hardware alarm $alarm-num (1 or 2) from the given $alarm.

  Alarm 2 has no seconds. The seconds of the $alarm are ignored for alarm 2, and
    the alarm triggers when the seconds of the time are 00.
  */
  set-alarm alarm-num/int alarm/AlarmSpec -> none:
    alarm-bit_ alarm-num
    if alarm-num == 1:
      registers.write-bytes REG-ALARM-1-START_ alarm.to-byte-array
    else:
      registers.write-bytes REG-ALARM-2-START_ alarm.to-byte-array[1..]

  /**
  Whether the alarm $alarm-num (1 or 2) has been triggered.
  */
  is-alarm-triggered alarm-num/int -> bool:
    mask := alarm-bit_ alarm-num
    return ((registers.read-u8 REG-STATUS_) & mask) != 0

  /**
  Clears the raised alarm $alarm-num (1 or 2).

  Alarms must be cleared in software.
  */
  clear-alarm alarm-num/int -> none:
    mask := alarm-bit_ alarm-num
    set-value-with-mask --register=REG-STATUS_ --mask=mask --value=0

  /** Returns the status and control register bit of the alarm $alarm-num. */
  alarm-bit_ alarm-num/int -> int:
    if alarm-num == 1: return ALARM-1-BIT_
    if alarm-num == 2: return ALARM-2-BIT_
    throw "INVALID_ALARM_NUMBER"


/**
The settings of a hardware alarm of the $Ds3231.

Each of the second, minute, hour and day is either matched or ignored. The
  object is immutable. Use $with to derive a changed copy.
*/
class AlarmSpec:
  static SECONDS-BYTE_ ::= 0
  static MINUTES-BYTE_ ::= 1
  static HOURS-BYTE_ ::= 2
  static DAY-BYTE_ ::= 3
  static DEFAULT-ARRAY_ ::= #[0x80, 0x80, 0x80, 0x80]

  // In accordance with ISO 8601, the week starts with Monday having the value 1.
  static UNSET ::= 0
  static MONDAY ::= 1
  static TUESDAY ::= 2
  static WEDNESDAY ::= 3
  static THURSDAY ::= 4
  static FRIDAY ::= 5
  static SATURDAY ::= 6
  static SUNDAY ::= 7
  static DAYS_ ::= {
    UNSET: "UNSET",
    MONDAY: "Monday",
    TUESDAY: "Tuesday",
    WEDNESDAY: "Wednesday",
    THURSDAY: "Thursday",
    FRIDAY: "Friday",
    SATURDAY: "Saturday",
    SUNDAY: "Sunday",
  }

  payload_/ByteArray := ?

  /**
  Creates an object from manually supplied data.

  Fields that are not given are ignored when matching the alarm. The $day is the
    day of the week (1 is Monday) if $weekly is true, or the day of the month
    otherwise. The $day and $weekly must be given together.
  */
  constructor
      --hour/int?=null
      --minute/int?=null
      --second/int?=null
      --day/int?=null
      --weekly/bool?=null:
    check-range_ hour 0 23
    check-range_ minute 0 59
    check-range_ second 0 59
    if (day == null) != (weekly == null): throw "DAY_AND_WEEKLY_REQUIRED_TOGETHER"
    if weekly != null: check-range_ day 1 (weekly ? 7 : 31)

    payload_ = DEFAULT-ARRAY_.copy
    if second: payload_[SECONDS-BYTE_] = encode-field_ second
    if minute: payload_[MINUTES-BYTE_] = encode-field_ minute
    if hour: payload_[HOURS-BYTE_] = encode-field_ hour
    if weekly != null:
      if weekly:
        payload_[DAY-BYTE_] = encode-day-field_ --day-of-week=day
      else:
        payload_[DAY-BYTE_] = encode-day-field_ --day-of-month=day

  /**
  Creates an object from register data.

  The $bytes are the 4 registers of alarm 1, or the 3 registers of alarm 2. Fields
    that contain invalid data are ignored when matching the alarm.
  */
  constructor.from-byte-array bytes/ByteArray:
    if bytes.size == 4:
      payload_ = bytes.copy
    else if bytes.size == 3:
      payload_ = #[0x80] + bytes
    else:
      throw "INVALID_ARGUMENT"
    sanitize_

  constructor.from-payload_ .payload_:

  /** Resets the fields that hold nonsensical data to 'ignored'. */
  sanitize_ -> none:
    if not (0 <= second <= 59): payload_[SECONDS-BYTE_] = 0x80
    if not (0 <= minute <= 59): payload_[MINUTES-BYTE_] = 0x80
    // Bit 6 of the hours byte selects the 12-hour mode, which this class does not use.
    if not (0 <= hour <= 23) or (payload_[HOURS-BYTE_] & 0x40) != 0:
      payload_[HOURS-BYTE_] = 0x80
    if must-day-match and not (1 <= day <= (is-weekly ? 7 : 31)):
      payload_[DAY-BYTE_] = 0x80

  /** Whether the seconds must match for the alarm to trigger. */
  must-seconds-match -> bool:
    return (payload_[SECONDS-BYTE_] & 0x80) == 0

  /** Whether the byte $byte (0 to 3, from seconds to day) must match. */
  must-match byte/int -> bool:
    if not 0 <= byte <= 3: throw "INVALID_ARGUMENT"
    return (payload_[byte] & 0x80) == 0

  /** Returns the register data of this alarm. */
  to-byte-array -> ByteArray:
    return payload_.copy

  /** Whether the day must match for the alarm to trigger. */
  must-day-match -> bool:
    return (payload_[DAY-BYTE_] & 0b1000_0000) == 0

  /** Whether the day is a day of the week. */
  is-weekly -> bool:
    return (payload_[DAY-BYTE_] & 0b0100_0000) != 0

  /** Whether the day is a day of the month. */
  is-monthly -> bool:
    return (payload_[DAY-BYTE_] & 0b0100_0000) == 0

  /** The day of the week (1 is Monday) or of the month. */
  day -> int:
    return bcd72int_ (payload_[DAY-BYTE_] & 0x3F)

  /** The hour in 24-hour format. */
  hour -> int:
    return bcd72int_ (payload_[HOURS-BYTE_] & 0x3F)

  /** The minute. */
  minute -> int:
    return bcd72int_ (payload_[MINUTES-BYTE_] & 0x7F)

  /** The second. */
  second -> int:
    return bcd72int_ (payload_[SECONDS-BYTE_] & 0x7F)

  stringify --debug/bool=false -> string:
    if debug: return "$payload_"
    sec-str := (must-match SECONDS-BYTE_) ? "$(%02d second)" : "*"
    min-str := (must-match MINUTES-BYTE_) ? "$(%02d minute)" : "*"
    hour-str := (must-match HOURS-BYTE_) ? "$(%02d hour)" : "*"
    match-sec := must-match SECONDS-BYTE_
    match-min := must-match MINUTES-BYTE_
    match-hour := must-match HOURS-BYTE_
    match-day := must-match DAY-BYTE_

    // Named cases:
    if not match-sec and not match-min and not match-hour and not match-day:
      return "every second"

    if match-sec and not match-min and not match-hour and not match-day:
      return "every minute at :$sec-str"

    if match-sec and match-min and not match-hour and not match-day:
      return "hourly at :$min-str:$sec-str"

    if match-sec and match-min and match-hour and not match-day:
      return "daily at $hour-str:$min-str:$sec-str"

    day-type := is-weekly ? "weekly" : "monthly"
    day-str := match-day ? "$(%02d day)" : "*"
    day-display := day-str
    if match-day and is-weekly: day-display = DAYS_.get day --if-absent=: day-str
    if match-day:
      return "$day-type on day $day-display at $hour-str:$min-str:$sec-str"

    return "custom at $hour-str:$min-str:$sec-str on day $day-display ($day-type)"

  /**
  Creates a copy of the object with supplied properties changed.

  Properties that are not given keep their value, including being ignored. To
    change the $day of an alarm that ignores the day, $weekly must be given too.
  */
  with -> AlarmSpec
      --hour/int?=null
      --minute/int?=null
      --second/int?=null
      --day/int?=null
      --weekly/bool?=null:
    check-range_ hour 0 23
    check-range_ minute 0 59
    check-range_ second 0 59
    result := AlarmSpec.from-payload_ payload_.copy
    if second: result.payload_[SECONDS-BYTE_] = encode-field_ second
    if minute: result.payload_[MINUTES-BYTE_] = encode-field_ minute
    if hour: result.payload_[HOURS-BYTE_] = encode-field_ hour
    if day != null or weekly != null:
      new-weekly := (weekly == null) ? is-weekly : weekly
      if day == null and not must-day-match: throw "DAY_REQUIRED"
      new-day := (day == null) ? this.day : day
      check-range_ new-day 1 (new-weekly ? 7 : 31)
      if new-weekly:
        result.payload_[DAY-BYTE_] = encode-day-field_ --day-of-week=new-day
      else:
        result.payload_[DAY-BYTE_] = encode-day-field_ --day-of-month=new-day
    return result

  static check-range_ value/int? low/int high/int -> none:
    if value != null and not low <= value <= high: throw "INVALID_ARGUMENT"

  static encode-field_ value/int -> int:
    return int2bcd7_ value

  static encode-day-field_ --day-of-month/int?=null --day-of-week/int?=null -> int:
    // If neither is provided, wildcard the day.
    if day-of-month == null and day-of-week == null:
      return 0x80

    if day-of-month != null:
      // DY/DT = 0, must match => bit7=0.
      return int2bcd7_ day-of-month

    // DY/DT = 1.
    return 0x40 | (int2bcd7_ day-of-week)

  static int2bcd7_ x/int -> int:
    return (((x / 10) << 4) | (x % 10)) & 0x7F

  static bcd72int_ x/int -> int:
    return ((x >> 4) * 10) + (x & 0x0F)

  /**
  Shortcut returning an $AlarmSpec for an alarm every second.
  */
  static every-second -> AlarmSpec:
    return AlarmSpec.from-byte-array DEFAULT-ARRAY_

  /**
  Shortcut returning an $AlarmSpec for an alarm every minute.

  Note: Alarm 2 can't match seconds. Alarms when seconds reach $seconds for
    Alarm 1, or when seconds=00 for Alarm 2.
  */
  static every-minute --seconds/int=0 -> AlarmSpec:
    return AlarmSpec --second=seconds

  /**
  Shortcut returning an $AlarmSpec for an alarm hourly.

  Alarm will trigger when minutes and seconds match. Will trigger on the hour
    if both are set to 00.
  */
  static every-hour --second/int=0 --minute/int=0 -> AlarmSpec:
    return AlarmSpec --minute=minute --second=second

  /**
  Shortcut returning an $AlarmSpec for an alarm daily.
  */
  static every-day --second/int=0 --minute/int=0 --hour/int=0 -> AlarmSpec:
    return AlarmSpec --hour=hour --minute=minute --second=second

  /**
  Shortcut returning an $AlarmSpec for an alarm weekly.
  */
  static weekly --day-of-week/int --hour/int=0 --minute/int=0 --second/int=0 -> AlarmSpec:
    return AlarmSpec --day=day-of-week --weekly --hour=hour --minute=minute --second=second

  /**
  Shortcut returning an $AlarmSpec for an alarm monthly.
  */
  static monthly --day-of-month/int --hour/int=0 --minute/int=0 --second/int=0 -> AlarmSpec:
    return AlarmSpec --day=day-of-month --no-weekly --hour=hour --minute=minute --second=second
