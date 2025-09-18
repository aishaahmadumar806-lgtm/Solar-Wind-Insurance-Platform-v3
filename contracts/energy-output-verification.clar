;; Energy Output Verification Smart Contract
;; Verifies actual energy production against expected output for insurance claims
;; Manages policy terms, conditions, and automated payout processing

;; ============================
;; Constants and Error Definitions
;; ============================

(define-constant CONTRACT_OWNER tx-sender)
(define-constant ERR_UNAUTHORIZED (err u300))
(define-constant ERR_INVALID_DATA (err u301))
(define-constant ERR_POLICY_NOT_FOUND (err u302))
(define-constant ERR_INSUFFICIENT_PREMIUM (err u303))
(define-constant ERR_POLICY_EXPIRED (err u304))
(define-constant ERR_CLAIM_ALREADY_PROCESSED (err u305))
(define-constant ERR_INSUFFICIENT_COVERAGE (err u306))
(define-constant ERR_INVALID_THRESHOLD (err u307))
(define-constant ERR_PAYOUT_FAILED (err u308))
(define-constant ERR_CONTRACT_PAUSED (err u309))

;; ============================
;; Data Variables
;; ============================

(define-data-var contract-admin principal CONTRACT_OWNER)
(define-data-var is-contract-paused bool false)
(define-data-var minimum-policy-duration uint u2160) ;; 15 days in blocks (assuming 10 min blocks)
(define-data-var maximum-policy-duration uint u52560) ;; 365 days in blocks
(define-data-var base-premium-rate uint u100) ;; Base premium rate per kW per day (STX * 1000000)
(define-data-var minimum-payout-threshold uint u8000) ;; 80% threshold * 100
(define-data-var claim-processing-fee uint u10000000) ;; 10 STX in microSTX

;; ============================
;; Data Maps
;; ============================

;; Store insurance policies
(define-map insurance-policies
  { policy-id: (string-ascii 64) }
  {
    policy-holder: principal,
    location-id: (string-ascii 64),
    energy-type: (string-ascii 16), ;; "solar", "wind", "hybrid"
    coverage-amount: uint, ;; Maximum payout in microSTX
    premium-paid: uint, ;; Total premium paid in microSTX
    policy-start: uint, ;; Block height
    policy-end: uint, ;; Block height
    expected-daily-output: uint, ;; kWh * 1000
    payout-threshold: uint, ;; Percentage * 100 (e.g., 8000 = 80%)
    is-active: bool,
    claims-count: uint,
    total-payouts: uint ;; Total paid out in microSTX
  }
)

;; Store energy production records
(define-map energy-production-records
  { location-id: (string-ascii 64), date: uint }
  {
    actual-output: uint, ;; kWh * 1000
    expected-output: uint, ;; kWh * 1000
    weather-factor: uint, ;; Impact factor * 100 (100 = normal, <100 = adverse)
    data-sources: (list 5 (string-ascii 64)), ;; List of data source IDs
    verification-status: (string-ascii 32),
    timestamp-recorded: uint,
    measurement-quality: uint ;; Quality score 0-100
  }
)

;; Store insurance claims
(define-map insurance-claims
  { claim-id: (string-ascii 64) }
  {
    policy-id: (string-ascii 64),
    claimant: principal,
    claim-date: uint,
    production-shortfall: uint, ;; kWh * 1000
    expected-production: uint, ;; kWh * 1000
    actual-production: uint, ;; kWh * 1000
    weather-conditions: { solar-irradiance: uint, wind-speed: uint, temperature: uint },
    claim-amount: uint, ;; Requested payout in microSTX
    processing-status: (string-ascii 32), ;; "pending", "approved", "rejected", "paid"
    approval-timestamp: (optional uint),
    payout-amount: uint, ;; Actual payout in microSTX
    rejection-reason: (optional (string-utf8 256))
  }
)

;; Store daily verification summaries
(define-map daily-verification-summary
  { location-id: (string-ascii 64), date: uint }
  {
    policies-count: uint,
    total-expected-output: uint,
    total-actual-output: uint,
    performance-ratio: uint, ;; Actual/Expected * 10000
    weather-impact-score: uint, ;; Combined weather impact * 100
    claims-triggered: uint,
    total-claim-amount: uint,
    data-confidence: uint ;; Confidence in measurements * 100
  }
)

;; Store premium calculation factors
(define-map location-risk-factors
  { location-id: (string-ascii 64) }
  {
    weather-risk-score: uint, ;; 0-1000 (higher = riskier)
    historical-performance: uint, ;; Average performance ratio * 100
    equipment-reliability: uint, ;; Equipment reliability score * 100
    data-availability: uint, ;; Data source reliability * 100
    base-premium-multiplier: uint, ;; Multiplier * 1000 (1000 = 1.0x)
    last-assessment: uint
  }
)

;; ============================
;; Authorization Functions
;; ============================

(define-private (is-contract-admin (user principal))
  (is-eq user (var-get contract-admin))
)

(define-private (is-policy-holder (policy-id (string-ascii 64)) (user principal))
  (match (map-get? insurance-policies { policy-id: policy-id })
    policy-data (is-eq (get policy-holder policy-data) user)
    false
  )
)

(define-private (is-contract-active)
  (not (var-get is-contract-paused))
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

(define-public (pause-contract)
  (begin
    (asserts! (is-contract-admin tx-sender) ERR_UNAUTHORIZED)
    (var-set is-contract-paused true)
    (ok true)
  )
)

(define-public (resume-contract)
  (begin
    (asserts! (is-contract-admin tx-sender) ERR_UNAUTHORIZED)
    (var-set is-contract-paused false)
    (ok true)
  )
)

(define-public (update-premium-parameters
  (base-rate uint)
  (minimum-threshold uint)
  (processing-fee uint)
)
  (begin
    (asserts! (is-contract-admin tx-sender) ERR_UNAUTHORIZED)
    (asserts! (> base-rate u0) ERR_INVALID_DATA)
    (asserts! (and (> minimum-threshold u0) (<= minimum-threshold u10000)) ERR_INVALID_THRESHOLD)
    
    (var-set base-premium-rate base-rate)
    (var-set minimum-payout-threshold minimum-threshold)
    (var-set claim-processing-fee processing-fee)
    (ok true)
  )
)

(define-public (set-location-risk-factors
  (location-id (string-ascii 64))
  (weather-risk uint)
  (historical-performance uint)
  (equipment-reliability uint)
  (data-availability uint)
  (premium-multiplier uint)
)
  (begin
    (asserts! (is-contract-admin tx-sender) ERR_UNAUTHORIZED)
    (asserts! (<= weather-risk u1000) ERR_INVALID_DATA)
    (asserts! (<= historical-performance u15000) ERR_INVALID_DATA) ;; Allow up to 150% performance
    (asserts! (<= equipment-reliability u10000) ERR_INVALID_DATA)
    (asserts! (<= data-availability u10000) ERR_INVALID_DATA)
    (asserts! (> premium-multiplier u0) ERR_INVALID_DATA)
    
    (map-set location-risk-factors
      { location-id: location-id }
      {
        weather-risk-score: weather-risk,
        historical-performance: historical-performance,
        equipment-reliability: equipment-reliability,
        data-availability: data-availability,
        base-premium-multiplier: premium-multiplier,
        last-assessment: block-height
      }
    )
    (ok true)
  )
)

;; ============================
;; Policy Management Functions
;; ============================

(define-public (create-insurance-policy
  (policy-id (string-ascii 64))
  (location-id (string-ascii 64))
  (energy-type (string-ascii 16))
  (coverage-amount uint)
  (policy-duration uint)
  (expected-daily-output uint)
  (payout-threshold uint)
)
  (let (
    (premium-amount (calculate-premium-cost location-id coverage-amount policy-duration))
  )
    (begin
      (asserts! (is-contract-active) ERR_CONTRACT_PAUSED)
      (asserts! (>= (stx-get-balance tx-sender) premium-amount) ERR_INSUFFICIENT_PREMIUM)
      (asserts! (and (>= policy-duration (var-get minimum-policy-duration)) 
                     (<= policy-duration (var-get maximum-policy-duration))) ERR_INVALID_DATA)
      (asserts! (and (>= payout-threshold (var-get minimum-payout-threshold)) 
                     (<= payout-threshold u10000)) ERR_INVALID_THRESHOLD)
      (asserts! (> expected-daily-output u0) ERR_INVALID_DATA)
      
      ;; Transfer premium from policy holder to contract
      (try! (stx-transfer? premium-amount tx-sender (as-contract tx-sender)))
      
      ;; Create the policy
      (map-set insurance-policies
        { policy-id: policy-id }
        {
          policy-holder: tx-sender,
          location-id: location-id,
          energy-type: energy-type,
          coverage-amount: coverage-amount,
          premium-paid: premium-amount,
          policy-start: block-height,
          policy-end: (+ block-height policy-duration),
          expected-daily-output: expected-daily-output,
          payout-threshold: payout-threshold,
          is-active: true,
          claims-count: u0,
          total-payouts: u0
        }
      )
      
      (ok policy-id)
    )
  )
)

(define-private (calculate-premium-cost 
  (location-id (string-ascii 64))
  (coverage-amount uint)
  (duration uint)
)
  (let (
    (base-rate (var-get base-premium-rate))
    (risk-factors (default-to 
                    { weather-risk-score: u300, base-premium-multiplier: u1000 }
                    (map-get? location-risk-factors { location-id: location-id })))
    (risk-multiplier (get base-premium-multiplier risk-factors))
    (weather-factor (+ u1000 (/ (get weather-risk-score risk-factors) u10))) ;; Convert risk to multiplier
  )
    ;; Premium = (base-rate * coverage * duration * risk-multiplier * weather-factor) / (1000 * 1000)
    (/ (* (* (* base-rate coverage-amount) duration) (* risk-multiplier weather-factor)) u1000000000)
  )
)

(define-public (renew-policy
  (policy-id (string-ascii 64))
  (additional-duration uint)
)
  (let (
    (policy (unwrap! (map-get? insurance-policies { policy-id: policy-id }) ERR_POLICY_NOT_FOUND))
    (renewal-premium (calculate-premium-cost 
                       (get location-id policy) 
                       (get coverage-amount policy) 
                       additional-duration))
  )
    (begin
      (asserts! (is-contract-active) ERR_CONTRACT_PAUSED)
      (asserts! (is-policy-holder policy-id tx-sender) ERR_UNAUTHORIZED)
      (asserts! (get is-active policy) ERR_POLICY_EXPIRED)
      (asserts! (>= (stx-get-balance tx-sender) renewal-premium) ERR_INSUFFICIENT_PREMIUM)
      
      ;; Transfer renewal premium
      (try! (stx-transfer? renewal-premium tx-sender (as-contract tx-sender)))
      
      ;; Update policy
      (map-set insurance-policies
        { policy-id: policy-id }
        (merge policy {
          policy-end: (+ (get policy-end policy) additional-duration),
          premium-paid: (+ (get premium-paid policy) renewal-premium)
        })
      )
      
      (ok true)
    )
  )
)

;; ============================
;; Energy Production Recording
;; ============================

(define-public (record-energy-production
  (location-id (string-ascii 64))
  (date uint)
  (actual-output uint)
  (expected-output uint)
  (weather-factor uint)
  (data-sources (list 5 (string-ascii 64)))
  (measurement-quality uint)
)
  (begin
    (asserts! (is-contract-admin tx-sender) ERR_UNAUTHORIZED)
    (asserts! (is-contract-active) ERR_CONTRACT_PAUSED)
    (asserts! (> actual-output u0) ERR_INVALID_DATA)
    (asserts! (> expected-output u0) ERR_INVALID_DATA)
    (asserts! (<= weather-factor u20000) ERR_INVALID_DATA) ;; Allow up to 200% weather impact
    (asserts! (<= measurement-quality u100) ERR_INVALID_DATA)
    
    (map-set energy-production-records
      { location-id: location-id, date: date }
      {
        actual-output: actual-output,
        expected-output: expected-output,
        weather-factor: weather-factor,
        data-sources: data-sources,
        verification-status: "verified",
        timestamp-recorded: block-height,
        measurement-quality: measurement-quality
      }
    )
    
    ;; Check for potential claims
    (try! (check-and-trigger-claims location-id date actual-output expected-output))
    
    (ok true)
  )
)

;; ============================
;; Claims Processing
;; ============================

(define-private (check-and-trigger-claims
  (location-id (string-ascii 64))
  (date uint)
  (actual-output uint)
  (expected-output uint)
)
  (let (
    (performance-ratio (if (> expected-output u0) 
                         (/ (* actual-output u10000) expected-output) 
                         u10000))
  )
    ;; This would typically iterate through policies for this location
    ;; For simplicity, we'll just return ok
    (ok true)
  )
)

(define-public (submit-insurance-claim
  (claim-id (string-ascii 64))
  (policy-id (string-ascii 64))
  (claim-date uint)
  (expected-production uint)
  (actual-production uint)
  (solar-irradiance uint)
  (wind-speed uint)
  (temperature uint)
)
  (let (
    (policy (unwrap! (map-get? insurance-policies { policy-id: policy-id }) ERR_POLICY_NOT_FOUND))
    (shortfall (- expected-production actual-production))
    (performance-ratio (if (> expected-production u0) 
                         (/ (* actual-production u10000) expected-production) 
                         u10000))
  )
    (begin
      (asserts! (is-contract-active) ERR_CONTRACT_PAUSED)
      (asserts! (is-policy-holder policy-id tx-sender) ERR_UNAUTHORIZED)
      (asserts! (get is-active policy) ERR_POLICY_EXPIRED)
      (asserts! (and (>= claim-date (get policy-start policy)) 
                     (<= claim-date (get policy-end policy))) ERR_POLICY_EXPIRED)
      (asserts! (< performance-ratio (get payout-threshold policy)) ERR_INSUFFICIENT_COVERAGE)
      (asserts! (> shortfall u0) ERR_INVALID_DATA)
      
      (let (
        (claim-amount (calculate-claim-payout policy shortfall performance-ratio))
      )
        (map-set insurance-claims
          { claim-id: claim-id }
          {
            policy-id: policy-id,
            claimant: tx-sender,
            claim-date: claim-date,
            production-shortfall: shortfall,
            expected-production: expected-production,
            actual-production: actual-production,
            weather-conditions: { 
              solar-irradiance: solar-irradiance, 
              wind-speed: wind-speed, 
              temperature: temperature 
            },
            claim-amount: claim-amount,
            processing-status: "pending",
            approval-timestamp: none,
            payout-amount: u0,
            rejection-reason: none
          }
        )
        
        (ok claim-id)
      )
    )
  )
)

(define-private (calculate-claim-payout
  (policy { coverage-amount: uint, payout-threshold: uint, expected-daily-output: uint })
  (shortfall uint)
  (performance-ratio uint)
)
  (let (
    (coverage-per-kwh (/ (get coverage-amount policy) (get expected-daily-output policy)))
    (base-payout (* shortfall coverage-per-kwh))
    (threshold (get payout-threshold policy))
    ;; Higher shortfall = higher payout multiplier
    (payout-multiplier (if (< performance-ratio (/ threshold u2))
                         u15000 ;; 150% payout for severe shortfall
                         u10000)) ;; 100% payout for moderate shortfall
  )
    (/ (* base-payout payout-multiplier) u10000)
  )
)

(define-public (approve-claim (claim-id (string-ascii 64)))
  (let (
    (claim (unwrap! (map-get? insurance-claims { claim-id: claim-id }) ERR_POLICY_NOT_FOUND))
    (policy-id (get policy-id claim))
    (policy (unwrap! (map-get? insurance-policies { policy-id: policy-id }) ERR_POLICY_NOT_FOUND))
    (payout-amount (get claim-amount claim))
  )
    (begin
      (asserts! (is-contract-admin tx-sender) ERR_UNAUTHORIZED)
      (asserts! (is-eq (get processing-status claim) "pending") ERR_CLAIM_ALREADY_PROCESSED)
      (asserts! (>= (stx-get-balance (as-contract tx-sender)) payout-amount) ERR_PAYOUT_FAILED)
      
      ;; Process payout
      (try! (as-contract (stx-transfer? payout-amount tx-sender (get claimant claim))))
      
      ;; Update claim status
      (map-set insurance-claims
        { claim-id: claim-id }
        (merge claim {
          processing-status: "paid",
          approval-timestamp: (some block-height),
          payout-amount: payout-amount
        })
      )
      
      ;; Update policy statistics
      (map-set insurance-policies
        { policy-id: policy-id }
        (merge policy {
          claims-count: (+ (get claims-count policy) u1),
          total-payouts: (+ (get total-payouts policy) payout-amount)
        })
      )
      
      (ok true)
    )
  )
)

(define-public (reject-claim 
  (claim-id (string-ascii 64))
  (reason (string-utf8 256))
)
  (let (
    (claim (unwrap! (map-get? insurance-claims { claim-id: claim-id }) ERR_POLICY_NOT_FOUND))
  )
    (begin
      (asserts! (is-contract-admin tx-sender) ERR_UNAUTHORIZED)
      (asserts! (is-eq (get processing-status claim) "pending") ERR_CLAIM_ALREADY_PROCESSED)
      
      (map-set insurance-claims
        { claim-id: claim-id }
        (merge claim {
          processing-status: "rejected",
          approval-timestamp: (some block-height),
          rejection-reason: (some reason)
        })
      )
      
      (ok true)
    )
  )
)

;; ============================
;; Data Retrieval Functions
;; ============================

(define-read-only (get-policy-info (policy-id (string-ascii 64)))
  (map-get? insurance-policies { policy-id: policy-id })
)

(define-read-only (get-production-record 
  (location-id (string-ascii 64)) 
  (date uint)
)
  (map-get? energy-production-records { location-id: location-id, date: date })
)

(define-read-only (get-claim-info (claim-id (string-ascii 64)))
  (map-get? insurance-claims { claim-id: claim-id })
)

(define-read-only (get-location-risk-info (location-id (string-ascii 64)))
  (map-get? location-risk-factors { location-id: location-id })
)

(define-read-only (get-daily-summary 
  (location-id (string-ascii 64)) 
  (date uint)
)
  (map-get? daily-verification-summary { location-id: location-id, date: date })
)

;; ============================
;; Utility Functions
;; ============================

(define-read-only (get-contract-admin)
  (var-get contract-admin)
)

(define-read-only (is-contract-paused)
  (var-get is-contract-paused)
)

(define-read-only (get-premium-parameters)
  {
    base-rate: (var-get base-premium-rate),
    minimum-threshold: (var-get minimum-payout-threshold),
    processing-fee: (var-get claim-processing-fee)
  }
)

(define-read-only (calculate-premium-quote
  (location-id (string-ascii 64))
  (coverage-amount uint)
  (duration uint)
)
  (calculate-premium-cost location-id coverage-amount duration)
)

;; ============================
;; Analytics Functions
;; ============================

(define-public (generate-daily-summary
  (location-id (string-ascii 64))
  (date uint)
  (policies-data (list 10 { policy-id: (string-ascii 64), expected: uint, actual: uint }))
)
  (begin
    (asserts! (is-contract-admin tx-sender) ERR_UNAUTHORIZED)
    
    (let (
      (total-expected (fold + (map get-expected policies-data) u0))
      (total-actual (fold + (map get-actual policies-data) u0))
      (performance-ratio (if (> total-expected u0) 
                           (/ (* total-actual u10000) total-expected) 
                           u10000))
      (policies-count (len policies-data))
    )
      (map-set daily-verification-summary
        { location-id: location-id, date: date }
        {
          policies-count: policies-count,
          total-expected-output: total-expected,
          total-actual-output: total-actual,
          performance-ratio: performance-ratio,
          weather-impact-score: u10000, ;; Simplified - would be calculated from weather data
          claims-triggered: u0, ;; Would be calculated based on thresholds
          total-claim-amount: u0, ;; Would be sum of claims for the day
          data-confidence: u95 ;; Simplified confidence score
        }
      )
      
      (ok true)
    )
  )
)

;; Helper functions for analytics
(define-private (get-expected (policy-data { policy-id: (string-ascii 64), expected: uint, actual: uint }))
  (get expected policy-data)
)

(define-private (get-actual (policy-data { policy-id: (string-ascii 64), expected: uint, actual: uint }))
  (get actual policy-data)
)