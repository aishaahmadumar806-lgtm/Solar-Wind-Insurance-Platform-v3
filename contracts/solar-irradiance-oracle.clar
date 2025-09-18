;; Solar Irradiance Oracle Smart Contract
;; Manages solar irradiance data collection and validation for insurance platform
;; Provides authenticated weather data feeds and calculates solar energy production estimates

;; ============================
;; Constants and Error Definitions
;; ============================

(define-constant CONTRACT_OWNER tx-sender)
(define-constant ERR_UNAUTHORIZED (err u100))
(define-constant ERR_INVALID_DATA (err u101))
(define-constant ERR_DATA_SOURCE_NOT_FOUND (err u102))
(define-constant ERR_INSUFFICIENT_PERMISSIONS (err u103))
(define-constant ERR_INVALID_LOCATION (err u104))
(define-constant ERR_DATA_EXPIRED (err u105))

;; ============================
;; Data Variables
;; ============================

(define-data-var contract-admin principal CONTRACT_OWNER)
(define-data-var data-update-threshold uint u3600) ;; 1 hour in seconds
(define-data-var minimum-irradiance-sources uint u3) ;; Minimum sources for validation

;; ============================
;; Data Maps
;; ============================

;; Store authorized data sources
(define-map authorized-data-sources
  { source-id: (string-ascii 64) }
  {
    source-name: (string-utf8 128),
    api-endpoint: (string-ascii 256),
    is-active: bool,
    reliability-score: uint,
    last-update: uint
  }
)

;; Store irradiance readings by location and timestamp
(define-map irradiance-readings
  { location-id: (string-ascii 64), timestamp: uint }
  {
    irradiance-value: uint, ;; W/m2 * 100 (for decimal precision)
    source-id: (string-ascii 64),
    temperature: uint, ;; Celsius * 100
    cloud-cover: uint, ;; Percentage * 100
    humidity: uint, ;; Percentage * 100
    validation-status: (string-ascii 32)
  }
)

;; Store location metadata
(define-map registered-locations
  { location-id: (string-ascii 64) }
  {
    latitude: int, ;; Degrees * 1000000 (for precision)
    longitude: int, ;; Degrees * 1000000 (for precision)
    elevation: uint, ;; Meters above sea level
    timezone: (string-ascii 32),
    installation-capacity: uint, ;; kW capacity
    panel-efficiency: uint, ;; Efficiency percentage * 100
    tilt-angle: uint, ;; Degrees * 100
    azimuth-angle: uint ;; Degrees * 100
  }
)

;; Store aggregated daily irradiance data
(define-map daily-irradiance-summary
  { location-id: (string-ascii 64), date: uint }
  {
    average-irradiance: uint,
    peak-irradiance: uint,
    total-daily-irradiance: uint, ;; kWh/m2/day * 1000
    number-of-readings: uint,
    data-quality-score: uint,
    predicted-energy-output: uint ;; kWh * 1000
  }
)

;; ============================
;; Authorization Functions
;; ============================

(define-private (is-contract-admin (user principal))
  (is-eq user (var-get contract-admin))
)

(define-private (is-authorized-source (source-id (string-ascii 64)))
  (match (map-get? authorized-data-sources { source-id: source-id })
    source-data (get is-active source-data)
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

(define-public (register-data-source 
  (source-id (string-ascii 64))
  (source-name (string-utf8 128))
  (api-endpoint (string-ascii 256))
  (reliability-score uint)
)
  (begin
    (asserts! (is-contract-admin tx-sender) ERR_UNAUTHORIZED)
    (asserts! (and (> reliability-score u0) (<= reliability-score u100)) ERR_INVALID_DATA)
    
    (map-set authorized-data-sources
      { source-id: source-id }
      {
        source-name: source-name,
        api-endpoint: api-endpoint,
        is-active: true,
        reliability-score: reliability-score,
        last-update: block-height
      }
    )
    (ok true)
  )
)

(define-public (update-source-status 
  (source-id (string-ascii 64))
  (is-active bool)
  (reliability-score uint)
)
  (begin
    (asserts! (is-contract-admin tx-sender) ERR_UNAUTHORIZED)
    (asserts! (and (> reliability-score u0) (<= reliability-score u100)) ERR_INVALID_DATA)
    
    (match (map-get? authorized-data-sources { source-id: source-id })
      source-data
        (begin
          (map-set authorized-data-sources
            { source-id: source-id }
            (merge source-data {
              is-active: is-active,
              reliability-score: reliability-score,
              last-update: block-height
            })
          )
          (ok true)
        )
      ERR_DATA_SOURCE_NOT_FOUND
    )
  )
)

(define-public (register-location
  (location-id (string-ascii 64))
  (latitude int)
  (longitude int)
  (elevation uint)
  (timezone (string-ascii 32))
  (installation-capacity uint)
  (panel-efficiency uint)
  (tilt-angle uint)
  (azimuth-angle uint)
)
  (begin
    (asserts! (is-contract-admin tx-sender) ERR_UNAUTHORIZED)
    (asserts! (and (>= latitude -90000000) (<= latitude 90000000)) ERR_INVALID_LOCATION)
    (asserts! (and (>= longitude -180000000) (<= longitude 180000000)) ERR_INVALID_LOCATION)
    (asserts! (and (> panel-efficiency u0) (<= panel-efficiency u10000)) ERR_INVALID_DATA)
    
    (map-set registered-locations
      { location-id: location-id }
      {
        latitude: latitude,
        longitude: longitude,
        elevation: elevation,
        timezone: timezone,
        installation-capacity: installation-capacity,
        panel-efficiency: panel-efficiency,
        tilt-angle: tilt-angle,
        azimuth-angle: azimuth-angle
      }
    )
    (ok true)
  )
)

;; ============================
;; Data Input Functions
;; ============================

(define-public (submit-irradiance-reading
  (location-id (string-ascii 64))
  (timestamp uint)
  (irradiance-value uint)
  (source-id (string-ascii 64))
  (temperature uint)
  (cloud-cover uint)
  (humidity uint)
)
  (begin
    (asserts! (is-authorized-source source-id) ERR_UNAUTHORIZED)
    (asserts! (is-some (map-get? registered-locations { location-id: location-id })) ERR_INVALID_LOCATION)
    (asserts! (and (>= irradiance-value u0) (<= irradiance-value u150000)) ERR_INVALID_DATA) ;; Max 1500 W/m2
    (asserts! (and (>= temperature u22315) (<= temperature u32315)) ERR_INVALID_DATA) ;; -50C to 60C in Kelvin*100
    (asserts! (<= cloud-cover u10000) ERR_INVALID_DATA) ;; 0-100% * 100
    (asserts! (<= humidity u10000) ERR_INVALID_DATA) ;; 0-100% * 100
    
    ;; Validate timestamp (not too old or in future)
    (asserts! (and 
      (>= timestamp (- block-height u144)) ;; Not older than 1 day (144 blocks)
      (<= timestamp (+ block-height u6)) ;; Not more than 6 blocks in future
    ) ERR_DATA_EXPIRED)
    
    (map-set irradiance-readings
      { location-id: location-id, timestamp: timestamp }
      {
        irradiance-value: irradiance-value,
        source-id: source-id,
        temperature: temperature,
        cloud-cover: cloud-cover,
        humidity: humidity,
        validation-status: "pending"
      }
    )
    
    ;; Update source last-update time
    (match (map-get? authorized-data-sources { source-id: source-id })
      source-data
        (map-set authorized-data-sources
          { source-id: source-id }
          (merge source-data { last-update: block-height })
        )
      true
    )
    
    (ok true)
  )
)

;; ============================
;; Data Validation Functions
;; ============================

(define-public (validate-reading
  (location-id (string-ascii 64))
  (timestamp uint)
  (validation-status (string-ascii 32))
)
  (begin
    (asserts! (is-contract-admin tx-sender) ERR_UNAUTHORIZED)
    
    (match (map-get? irradiance-readings { location-id: location-id, timestamp: timestamp })
      reading-data
        (begin
          (map-set irradiance-readings
            { location-id: location-id, timestamp: timestamp }
            (merge reading-data { validation-status: validation-status })
          )
          (ok true)
        )
      ERR_INVALID_DATA
    )
  )
)

;; ============================
;; Data Retrieval Functions
;; ============================

(define-read-only (get-irradiance-reading
  (location-id (string-ascii 64))
  (timestamp uint)
)
  (map-get? irradiance-readings { location-id: location-id, timestamp: timestamp })
)

(define-read-only (get-location-info (location-id (string-ascii 64)))
  (map-get? registered-locations { location-id: location-id })
)

(define-read-only (get-data-source-info (source-id (string-ascii 64)))
  (map-get? authorized-data-sources { source-id: source-id })
)

;; ============================
;; Energy Calculation Functions
;; ============================

(define-private (calculate-energy-output
  (irradiance uint)
  (installation-capacity uint)
  (panel-efficiency uint)
  (temperature uint)
)
  ;; Simplified energy calculation: Power = Irradiance * Area * Efficiency * Temperature_factor
  ;; Temperature factor reduces efficiency by 0.4% per degree above 25C
  (let (
    (temp-celsius (/ (- temperature u27315) u100)) ;; Convert from Kelvin*100 to Celsius
    (temp-factor (if (> temp-celsius u25)
                    (- u10000 (* (- temp-celsius u25) u40)) ;; 0.4% per degree above 25C
                    u10000)) ;; No reduction below 25C
    (base-power (* (* irradiance installation-capacity) panel-efficiency))
  )
    (/ (* base-power temp-factor) u100000000) ;; Adjust for all scaling factors
  )
)

(define-public (calculate-expected-daily-output
  (location-id (string-ascii 64))
  (date uint)
)
  (let (
    (location-data (unwrap! (get-location-info location-id) ERR_INVALID_LOCATION))
    (daily-summary (map-get? daily-irradiance-summary { location-id: location-id, date: date }))
  )
    (match daily-summary
      summary-data
        (ok (get predicted-energy-output summary-data))
      (begin
        ;; Calculate expected output based on location parameters and historical data
        ;; This would typically involve more complex calculations
        (let (
          (capacity (get installation-capacity location-data))
          (efficiency (get panel-efficiency location-data))
          ;; Assume average irradiance of 5 kWh/m2/day for calculation
          (avg-irradiance u50000)
        )
          (ok (calculate-energy-output avg-irradiance capacity efficiency u29815)) ;; 25C
        )
      )
    )
  )
)

;; ============================
;; Daily Summary Functions
;; ============================

(define-public (generate-daily-summary
  (location-id (string-ascii 64))
  (date uint)
  (readings-list (list 24 { timestamp: uint, irradiance: uint, temperature: uint }))
)
  (begin
    (asserts! (is-contract-admin tx-sender) ERR_UNAUTHORIZED)
    (asserts! (is-some (get-location-info location-id)) ERR_INVALID_LOCATION)
    
    (let (
      (location-data (unwrap! (get-location-info location-id) ERR_INVALID_LOCATION))
      (total-irradiance (fold + (map get-irradiance readings-list) u0))
      (peak-irradiance (fold max (map get-irradiance readings-list) u0))
      (num-readings (len readings-list))
      (avg-irradiance (if (> num-readings u0) (/ total-irradiance num-readings) u0))
      (avg-temp (if (> num-readings u0) 
                   (/ (fold + (map get-temperature readings-list) u0) num-readings) 
                   u29815))
      (predicted-output (calculate-energy-output 
                          avg-irradiance 
                          (get installation-capacity location-data)
                          (get panel-efficiency location-data)
                          avg-temp))
    )
      (map-set daily-irradiance-summary
        { location-id: location-id, date: date }
        {
          average-irradiance: avg-irradiance,
          peak-irradiance: peak-irradiance,
          total-daily-irradiance: (/ total-irradiance u100), ;; Convert to kWh/m2
          number-of-readings: num-readings,
          data-quality-score: (if (>= num-readings u18) u100 (* (/ num-readings u18) u100)),
          predicted-energy-output: predicted-output
        }
      )
      (ok true)
    )
  )
)

;; Helper functions for daily summary
(define-private (get-irradiance (reading { timestamp: uint, irradiance: uint, temperature: uint }))
  (get irradiance reading)
)

(define-private (get-temperature (reading { timestamp: uint, irradiance: uint, temperature: uint }))
  (get temperature reading)
)

(define-read-only (get-daily-summary
  (location-id (string-ascii 64))
  (date uint)
)
  (map-get? daily-irradiance-summary { location-id: location-id, date: date })
)

;; ============================
;; Utility Functions
;; ============================

(define-read-only (get-contract-admin)
  (var-get contract-admin)
)

(define-read-only (get-update-threshold)
  (var-get data-update-threshold)
)

(define-public (set-update-threshold (new-threshold uint))
  (begin
    (asserts! (is-contract-admin tx-sender) ERR_UNAUTHORIZED)
    (var-set data-update-threshold new-threshold)
    (ok true)
  )
)