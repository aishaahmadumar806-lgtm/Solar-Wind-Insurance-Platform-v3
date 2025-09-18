;; Wind Speed Monitoring Smart Contract
;; Monitors wind speed measurements across different locations for renewable energy insurance
;; Validates wind data from multiple sources and calculates wind energy generation potential

;; ============================
;; Constants and Error Definitions
;; ============================

(define-constant CONTRACT_OWNER tx-sender)
(define-constant ERR_UNAUTHORIZED (err u200))
(define-constant ERR_INVALID_DATA (err u201))
(define-constant ERR_STATION_NOT_FOUND (err u202))
(define-constant ERR_INSUFFICIENT_PERMISSIONS (err u203))
(define-constant ERR_INVALID_LOCATION (err u204))
(define-constant ERR_DATA_EXPIRED (err u205))
(define-constant ERR_WIND_STATION_OFFLINE (err u206))

;; ============================
;; Data Variables
;; ============================

(define-data-var contract-admin principal CONTRACT_OWNER)
(define-data-var data-update-interval uint u1800) ;; 30 minutes in seconds
(define-data-var minimum-wind-sources uint u2) ;; Minimum sources for validation
(define-data-var cut-in-wind-speed uint u300) ;; 3.0 m/s * 100 (typical turbine cut-in speed)
(define-data-var cut-out-wind-speed uint u2500) ;; 25.0 m/s * 100 (typical turbine cut-out speed)

;; ============================
;; Data Maps
;; ============================

;; Store authorized wind monitoring stations
(define-map wind-monitoring-stations
  { station-id: (string-ascii 64) }
  {
    station-name: (string-utf8 128),
    location-id: (string-ascii 64),
    latitude: int, ;; Degrees * 1000000
    longitude: int, ;; Degrees * 1000000
    elevation: uint, ;; Meters above sea level
    anemometer-height: uint, ;; Height in meters * 100
    station-type: (string-ascii 32), ;; "weather", "turbine", "meteorological"
    is-active: bool,
    reliability-rating: uint, ;; 0-100 scale
    last-maintenance: uint,
    installation-date: uint
  }
)

;; Store wind speed measurements
(define-map wind-measurements
  { station-id: (string-ascii 64), timestamp: uint }
  {
    wind-speed: uint, ;; m/s * 100 (for decimal precision)
    wind-direction: uint, ;; Degrees * 100 (0-35999 representing 0-359.99 degrees)
    gust-speed: uint, ;; m/s * 100
    air-pressure: uint, ;; hPa * 100
    temperature: uint, ;; Celsius * 100
    humidity: uint, ;; Percentage * 100
    validation-status: (string-ascii 32),
    data-quality: uint ;; Quality score 0-100
  }
)

;; Store wind turbine specifications by location
(define-map wind-turbine-specs
  { location-id: (string-ascii 64) }
  {
    turbine-model: (string-utf8 64),
    rated-capacity: uint, ;; kW
    rotor-diameter: uint, ;; Meters * 100
    hub-height: uint, ;; Meters * 100
    cut-in-speed: uint, ;; m/s * 100
    rated-speed: uint, ;; m/s * 100
    cut-out-speed: uint, ;; m/s * 100
    number-of-turbines: uint,
    installation-date: uint,
    power-curve-coefficients: { a: int, b: int, c: int } ;; For power curve calculation
  }
)

;; Store hourly wind data summaries
(define-map hourly-wind-summary
  { location-id: (string-ascii 64), hour-timestamp: uint }
  {
    average-wind-speed: uint,
    maximum-wind-speed: uint,
    minimum-wind-speed: uint,
    average-direction: uint,
    turbulence-intensity: uint, ;; Percentage * 100
    data-points-count: uint,
    predicted-power-output: uint, ;; kWh * 1000
    capacity-factor: uint ;; Percentage * 100
  }
)

;; Store daily wind energy production estimates
(define-map daily-wind-production
  { location-id: (string-ascii 64), date: uint }
  {
    total-energy-estimate: uint, ;; kWh * 1000
    average-wind-speed: uint,
    maximum-wind-speed: uint,
    operating-hours: uint, ;; Hours * 100 (turbines operating)
    capacity-factor: uint, ;; Percentage * 100
    weather-downtime: uint, ;; Minutes of weather-related downtime
    data-quality-score: uint
  }
)

;; ============================
;; Authorization Functions
;; ============================

(define-private (is-contract-admin (user principal))
  (is-eq user (var-get contract-admin))
)

(define-private (is-station-active (station-id (string-ascii 64)))
  (match (map-get? wind-monitoring-stations { station-id: station-id })
    station-data (get is-active station-data)
    false
  )
)

;; ============================
;; Admin Functions
;; ============================

(define-public (set-contract-admin (new-admin principal))
  (begin
    (asserts! (is-contract-admin tx-sender) ERR_UNAUTHORIZED)
    (var-set contract-admin new-admin)
    (ok true)
  )
)

(define-public (register-wind-station
  (station-id (string-ascii 64))
  (station-name (string-utf8 128))
  (location-id (string-ascii 64))
  (latitude int)
  (longitude int)
  (elevation uint)
  (anemometer-height uint)
  (station-type (string-ascii 32))
  (reliability-rating uint)
)
  (begin
    (asserts! (is-contract-admin tx-sender) ERR_UNAUTHORIZED)
    (asserts! (and (>= latitude -90000000) (<= latitude 90000000)) ERR_INVALID_LOCATION)
    (asserts! (and (>= longitude -180000000) (<= longitude 180000000)) ERR_INVALID_LOCATION)
    (asserts! (<= reliability-rating u100) ERR_INVALID_DATA)
    (asserts! (> anemometer-height u100) ERR_INVALID_DATA) ;; At least 1 meter high
    
    (map-set wind-monitoring-stations
      { station-id: station-id }
      {
        station-name: station-name,
        location-id: location-id,
        latitude: latitude,
        longitude: longitude,
        elevation: elevation,
        anemometer-height: anemometer-height,
        station-type: station-type,
        is-active: true,
        reliability-rating: reliability-rating,
        last-maintenance: block-height,
        installation-date: block-height
      }
    )
    (ok true)
  )
)

(define-public (update-station-status
  (station-id (string-ascii 64))
  (is-active bool)
  (reliability-rating uint)
)
  (begin
    (asserts! (is-contract-admin tx-sender) ERR_UNAUTHORIZED)
    (asserts! (<= reliability-rating u100) ERR_INVALID_DATA)
    
    (match (map-get? wind-monitoring-stations { station-id: station-id })
      station-data
        (begin
          (map-set wind-monitoring-stations
            { station-id: station-id }
            (merge station-data {
              is-active: is-active,
              reliability-rating: reliability-rating,
              last-maintenance: block-height
            })
          )
          (ok true)
        )
      ERR_STATION_NOT_FOUND
    )
  )
)

(define-public (register-turbine-specs
  (location-id (string-ascii 64))
  (turbine-model (string-utf8 64))
  (rated-capacity uint)
  (rotor-diameter uint)
  (hub-height uint)
  (cut-in-speed uint)
  (rated-speed uint)
  (cut-out-speed uint)
  (number-of-turbines uint)
  (power-curve-a int)
  (power-curve-b int)
  (power-curve-c int)
)
  (begin
    (asserts! (is-contract-admin tx-sender) ERR_UNAUTHORIZED)
    (asserts! (> rated-capacity u0) ERR_INVALID_DATA)
    (asserts! (> number-of-turbines u0) ERR_INVALID_DATA)
    (asserts! (< cut-in-speed rated-speed) ERR_INVALID_DATA)
    (asserts! (< rated-speed cut-out-speed) ERR_INVALID_DATA)
    
    (map-set wind-turbine-specs
      { location-id: location-id }
      {
        turbine-model: turbine-model,
        rated-capacity: rated-capacity,
        rotor-diameter: rotor-diameter,
        hub-height: hub-height,
        cut-in-speed: cut-in-speed,
        rated-speed: rated-speed,
        cut-out-speed: cut-out-speed,
        number-of-turbines: number-of-turbines,
        installation-date: block-height,
        power-curve-coefficients: { a: power-curve-a, b: power-curve-b, c: power-curve-c }
      }
    )
    (ok true)
  )
)

;; ============================
;; Data Input Functions
;; ============================

(define-public (submit-wind-measurement
  (station-id (string-ascii 64))
  (timestamp uint)
  (wind-speed uint)
  (wind-direction uint)
  (gust-speed uint)
  (air-pressure uint)
  (temperature uint)
  (humidity uint)
)
  (begin
    (asserts! (is-station-active station-id) ERR_WIND_STATION_OFFLINE)
    (asserts! (<= wind-speed u10000) ERR_INVALID_DATA) ;; Max 100 m/s
    (asserts! (< wind-direction u36000) ERR_INVALID_DATA) ;; 0-359.99 degrees
    (asserts! (<= gust-speed u15000) ERR_INVALID_DATA) ;; Max 150 m/s
    (asserts! (and (>= air-pressure u80000) (<= air-pressure u110000)) ERR_INVALID_DATA) ;; 800-1100 hPa
    (asserts! (and (>= temperature u22315) (<= temperature u32315)) ERR_INVALID_DATA) ;; -50C to 60C
    (asserts! (<= humidity u10000) ERR_INVALID_DATA) ;; 0-100%
    
    ;; Validate timestamp (not too old or in future)
    (asserts! (and 
      (>= timestamp (- block-height u72)) ;; Not older than 12 hours
      (<= timestamp (+ block-height u6)) ;; Not more than 6 blocks in future
    ) ERR_DATA_EXPIRED)
    
    ;; Calculate data quality based on consistency checks
    (let (
      (quality-score (calculate-data-quality wind-speed gust-speed air-pressure))
    )
      (map-set wind-measurements
        { station-id: station-id, timestamp: timestamp }
        {
          wind-speed: wind-speed,
          wind-direction: wind-direction,
          gust-speed: gust-speed,
          air-pressure: air-pressure,
          temperature: temperature,
          humidity: humidity,
          validation-status: "pending",
          data-quality: quality-score
        }
      )
    )
    (ok true)
  )
)

;; ============================
;; Data Processing Functions
;; ============================

(define-private (calculate-data-quality 
  (wind-speed uint) 
  (gust-speed uint) 
  (air-pressure uint)
)
  ;; Basic quality assessment based on data consistency
  (let (
    (speed-consistency (if (<= (- gust-speed wind-speed) (* wind-speed u50)) u30 u10)) ;; Gust should be reasonable
    (pressure-validity (if (and (>= air-pressure u95000) (<= air-pressure u105000)) u40 u20)) ;; Normal pressure range
    (base-quality u30) ;; Base quality for any submitted data
  )
    (+ base-quality speed-consistency pressure-validity)
  )
)

(define-private (calculate-wind-power-output
  (wind-speed uint)
  (turbine-specs { rated-capacity: uint, cut-in-speed: uint, rated-speed: uint, cut-out-speed: uint, 
                   number-of-turbines: uint, power-curve-coefficients: { a: int, b: int, c: int } })
)
  ;; Calculate power output using simplified power curve
  ;; Power = a * v^3 + b * v^2 + c * v (where v is wind speed)
  (let (
    (cut-in (get cut-in-speed turbine-specs))
    (rated (get rated-speed turbine-specs))
    (cut-out (get cut-out-speed turbine-specs))
    (capacity (get rated-capacity turbine-specs))
    (turbines (get number-of-turbines turbine-specs))
    (coeffs (get power-curve-coefficients turbine-specs))
  )
    (if (or (< wind-speed cut-in) (> wind-speed cut-out))
      u0 ;; No power generation outside operating range
      (if (<= wind-speed rated)
        ;; Below rated speed: use power curve
        (let (
          (v (/ wind-speed u100)) ;; Convert to actual m/s
          (v2 (* v v))
          (v3 (* v2 v))
          (curve-power (+ (+ (* (get a coeffs) v3) (* (get b coeffs) v2)) (* (get c coeffs) v)))
        )
          (* (* (to-uint curve-power) turbines) u1000) ;; Convert to kW * 1000
        )
        ;; Above rated speed: constant rated power
        (* (* capacity turbines) u1000)
      )
    )
  )
)

;; ============================
;; Summary Generation Functions
;; ============================

(define-public (generate-hourly-summary
  (location-id (string-ascii 64))
  (hour-timestamp uint)
  (wind-measurements-list (list 60 { timestamp: uint, speed: uint, direction: uint, gust: uint }))
)
  (begin
    (asserts! (is-contract-admin tx-sender) ERR_UNAUTHORIZED)
    
    (let (
      (turbine-data (map-get? wind-turbine-specs { location-id: location-id }))
      (num-measurements (len wind-measurements-list))
      (total-speed (fold + (map get-speed wind-measurements-list) u0))
      (max-speed (fold max (map get-speed wind-measurements-list) u0))
      (min-speed (fold min (map get-speed wind-measurements-list) u10000))
      (avg-speed (if (> num-measurements u0) (/ total-speed num-measurements) u0))
      (avg-direction (calculate-average-direction wind-measurements-list))
      (turbulence (calculate-turbulence-intensity wind-measurements-list))
    )
      (let (
        (predicted-power (match turbine-data
                           specs (calculate-wind-power-output avg-speed specs)
                           u0))
        (capacity-factor (match turbine-data
                           specs (if (> (get rated-capacity specs) u0)
                                   (/ (* predicted-power u100) (* (get rated-capacity specs) (get number-of-turbines specs)))
                                   u0)
                           u0))
      )
        (map-set hourly-wind-summary
          { location-id: location-id, hour-timestamp: hour-timestamp }
          {
            average-wind-speed: avg-speed,
            maximum-wind-speed: max-speed,
            minimum-wind-speed: min-speed,
            average-direction: avg-direction,
            turbulence-intensity: turbulence,
            data-points-count: num-measurements,
            predicted-power-output: predicted-power,
            capacity-factor: capacity-factor
          }
        )
        (ok true)
      )
    )
  )
)

;; Helper functions for summary calculations
(define-private (get-speed (measurement { timestamp: uint, speed: uint, direction: uint, gust: uint }))
  (get speed measurement)
)

(define-private (calculate-average-direction (measurements (list 60 { timestamp: uint, speed: uint, direction: uint, gust: uint })))
  ;; Simplified direction average - would need more complex circular statistics in practice
  (let (
    (directions (map get-direction measurements))
    (total-direction (fold + directions u0))
    (count (len measurements))
  )
    (if (> count u0) (/ total-direction count) u0)
  )
)

(define-private (get-direction (measurement { timestamp: uint, speed: uint, direction: uint, gust: uint }))
  (get direction measurement)
)

(define-private (calculate-turbulence-intensity (measurements (list 60 { timestamp: uint, speed: uint, direction: uint, gust: uint })))
  ;; Simplified turbulence calculation
  (let (
    (speeds (map get-speed measurements))
    (avg-speed (/ (fold + speeds u0) (len measurements)))
    (gusts (map get-gust measurements))
    (avg-gust (/ (fold + gusts u0) (len measurements)))
  )
    (if (> avg-speed u0)
      (/ (* (- avg-gust avg-speed) u10000) avg-speed) ;; Turbulence intensity as percentage * 100
      u0)
  )
)

(define-private (get-gust (measurement { timestamp: uint, speed: uint, direction: uint, gust: uint }))
  (get gust measurement)
)

;; ============================
;; Daily Production Estimates
;; ============================

(define-public (generate-daily-production-estimate
  (location-id (string-ascii 64))
  (date uint)
  (hourly-summaries (list 24 { hour: uint, avg-speed: uint, max-speed: uint, power: uint }))
)
  (begin
    (asserts! (is-contract-admin tx-sender) ERR_UNAUTHORIZED)
    
    (let (
      (total-energy (fold + (map get-power hourly-summaries) u0))
      (avg-speed (/ (fold + (map get-avg-speed hourly-summaries) u0) (len hourly-summaries)))
      (max-speed (fold max (map get-max-speed hourly-summaries) u0))
      (operating-hours (calculate-operating-hours hourly-summaries))
      (turbine-data (map-get? wind-turbine-specs { location-id: location-id }))
    )
      (let (
        (capacity-factor (match turbine-data
                           specs (if (> (* (get rated-capacity specs) (get number-of-turbines specs)) u0)
                                   (/ (* total-energy u100) (* (* (get rated-capacity specs) (get number-of-turbines specs)) u24))
                                   u0)
                           u0))
        (downtime (calculate-weather-downtime hourly-summaries))
      )
        (map-set daily-wind-production
          { location-id: location-id, date: date }
          {
            total-energy-estimate: total-energy,
            average-wind-speed: avg-speed,
            maximum-wind-speed: max-speed,
            operating-hours: operating-hours,
            capacity-factor: capacity-factor,
            weather-downtime: downtime,
            data-quality-score: u95 ;; Simplified quality score
          }
        )
        (ok true)
      )
    )
  )
)

;; Helper functions for daily estimates
(define-private (get-power (summary { hour: uint, avg-speed: uint, max-speed: uint, power: uint }))
  (get power summary)
)

(define-private (get-avg-speed (summary { hour: uint, avg-speed: uint, max-speed: uint, power: uint }))
  (get avg-speed summary)
)

(define-private (get-max-speed (summary { hour: uint, avg-speed: uint, max-speed: uint, power: uint }))
  (get max-speed summary)
)

(define-private (calculate-operating-hours (summaries (list 24 { hour: uint, avg-speed: uint, max-speed: uint, power: uint })))
  ;; Count hours where power > 0
  (* (len (filter is-operating summaries)) u100) ;; Hours * 100
)

(define-private (is-operating (summary { hour: uint, avg-speed: uint, max-speed: uint, power: uint }))
  (> (get power summary) u0)
)

(define-private (calculate-weather-downtime (summaries (list 24 { hour: uint, avg-speed: uint, max-speed: uint, power: uint })))
  ;; Count minutes of weather-related downtime (high wind speeds)
  (* (len (filter has-weather-downtime summaries)) u60) ;; Hours to minutes
)

(define-private (has-weather-downtime (summary { hour: uint, avg-speed: uint, max-speed: uint, power: uint }))
  (and (is-eq (get power summary) u0) (> (get avg-speed summary) (var-get cut-out-wind-speed)))
)

;; ============================
;; Data Retrieval Functions
;; ============================

(define-read-only (get-wind-measurement
  (station-id (string-ascii 64))
  (timestamp uint)
)
  (map-get? wind-measurements { station-id: station-id, timestamp: timestamp })
)

(define-read-only (get-station-info (station-id (string-ascii 64)))
  (map-get? wind-monitoring-stations { station-id: station-id })
)

(define-read-only (get-turbine-specs (location-id (string-ascii 64)))
  (map-get? wind-turbine-specs { location-id: location-id })
)

(define-read-only (get-hourly-summary
  (location-id (string-ascii 64))
  (hour-timestamp uint)
)
  (map-get? hourly-wind-summary { location-id: location-id, hour-timestamp: hour-timestamp })
)

(define-read-only (get-daily-production
  (location-id (string-ascii 64))
  (date uint)
)
  (map-get? daily-wind-production { location-id: location-id, date: date })
)

;; ============================
;; Utility Functions
;; ============================

(define-read-only (get-contract-admin)
  (var-get contract-admin)
)

(define-read-only (get-update-interval)
  (var-get data-update-interval)
)

(define-public (set-wind-speed-thresholds 
  (cut-in uint) 
  (cut-out uint)
)
  (begin
    (asserts! (is-contract-admin tx-sender) ERR_UNAUTHORIZED)
    (asserts! (< cut-in cut-out) ERR_INVALID_DATA)
    (var-set cut-in-wind-speed cut-in)
    (var-set cut-out-wind-speed cut-out)
    (ok true)
  )
)

(define-read-only (get-wind-thresholds)
  {
    cut-in: (var-get cut-in-wind-speed),
    cut-out: (var-get cut-out-wind-speed)
  }
)