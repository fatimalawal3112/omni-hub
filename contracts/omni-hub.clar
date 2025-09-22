;; Omni-Hub Clarity Smart Contract
;; A complex milestone-based crowdfunding, staking, subscriptions, and auctions.

(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-INVALID (err u101))
(define-constant ERR-INSUFFICIENT (err u102))

;; ---------------------------------------------------------
;; Data Maps & Variables
;; ---------------------------------------------------------

;; ---------------------------------------------------------
;; Data Maps & Variables
;; ---------------------------------------------------------

(define-data-var dao-treasury principal tx-sender)

(define-map jobs {id: uint} { client: principal, worker: (optional principal), reward: uint, active: bool })
(define-map milestones {job-id: uint, index: uint} { description: (string-ascii 64), approved: bool, paid: bool })

(define-map stakes {user: principal} { amount: uint, unlock-height: uint })

(define-map subscriptions {user: principal} { expiry: uint })

(define-map auctions {id: uint} { seller: principal, highest-bidder: (optional principal), highest-bid: uint, end-block: uint, active: bool })

(define-data-var job-counter uint u0)
(define-data-var auction-counter uint u0)

;; ---------------------------------------------------------
;; Governance DAO Voting (Simple)
;; ---------------------------------------------------------

(define-map proposals {id: uint} { description: (string-ascii 128), votes-for: uint, votes-against: uint, executed: bool })
(define-data-var proposal-counter uint u0)

(define-map has-voted {proposal-id: uint, voter: principal} bool)

(define-public (submit-proposal (desc (string-ascii 128)))
  (let ((proposal-id (+ (var-get proposal-counter) u1)))
    (begin
      (asserts! (> (len desc) u0) ERR-INVALID)
      (var-set proposal-counter proposal-id)
      (map-set proposals {id: proposal-id} { description: desc, votes-for: u0, votes-against: u0, executed: false })
      (ok proposal-id)
    )
  )
)

(define-public (vote (proposal-id uint) (support bool))
  (if (is-some (map-get? has-voted {proposal-id: proposal-id, voter: tx-sender}))
      ERR-INVALID
      (let ((prop (unwrap! (map-get? proposals {id: proposal-id}) ERR-INVALID)))
        (begin
          (map-set has-voted {proposal-id: proposal-id, voter: tx-sender} true)
          (if support
              (map-set proposals {id: proposal-id} { description: (get description prop), votes-for: (+ u1 (get votes-for prop)), votes-against: (get votes-against prop), executed: (get executed prop) })
              (map-set proposals {id: proposal-id} { description: (get description prop), votes-for: (get votes-for prop), votes-against: (+ u1 (get votes-against prop)), executed: (get executed prop) })
          )
          (ok true)
        )
      )
  )
)

;; ---------------------------------------------------------
;; Freelance Job Marketplace + Milestones
;; ---------------------------------------------------------

(define-public (create-job (reward uint))
  (let ((job-id (+ (var-get job-counter) u1)))
    (begin
      (asserts! (> reward u0) ERR-INVALID)
      (var-set job-counter job-id)
      (asserts! 
        (map-set jobs 
          {id: job-id} 
          { client: tx-sender, worker: none, reward: reward, active: true }) 
        ERR-INVALID)
      (ok job-id)
    )
  )
)

(define-public (assign-worker (job-id uint) (worker principal))
  (let ((job (unwrap! (map-get? jobs {id: job-id}) ERR-INVALID)))
    (begin
      (asserts! (is-eq (get client job) tx-sender) ERR-NOT-AUTHORIZED)
      (asserts! (is-none (get worker job)) ERR-INVALID)
      (asserts! 
        (map-set jobs 
          {id: job-id} 
          { client: (get client job), worker: (some worker), reward: (get reward job), active: true }) 
        ERR-INVALID)
      (ok true)
    )))

(define-public (submit-milestone (job-id uint) (index uint) (desc (string-ascii 64)))
  (let ((job (unwrap! (map-get? jobs {id: job-id}) ERR-INVALID)))
    (begin
      (asserts! (is-some (get worker job)) ERR-INVALID)
      (asserts! (> (len desc) u0) ERR-INVALID)
      (asserts! (< index u100) ERR-INVALID)
      (asserts!
        (map-set milestones
          {job-id: job-id, index: index}
          { description: desc, approved: false, paid: false })
        ERR-INVALID)
      (ok true)
    )))

(define-public (approve-milestone (job-id uint) (index uint))
  (let ((job (unwrap! (map-get? jobs {id: job-id}) ERR-INVALID))
        (milestone (unwrap! (map-get? milestones {job-id: job-id, index: index}) ERR-INVALID)))
    (begin
      (asserts! (is-eq (get client job) tx-sender) ERR-NOT-AUTHORIZED)
      (asserts! (not (get approved milestone)) ERR-INVALID)
      (asserts!
        (map-set milestones 
          {job-id: job-id, index: index}
          (merge milestone { approved: true }))
        ERR-INVALID)
      (ok true))))

;; ---------------------------------------------------------
;; Staking
;; ---------------------------------------------------------

(define-public (stake (amount uint) (lock-period uint))
  (begin 
    (asserts! (> amount u0) ERR-INVALID)
    (asserts! (> lock-period u0) ERR-INVALID)
    (asserts! (>= (stx-get-balance tx-sender) amount) ERR-INSUFFICIENT)
    (asserts! 
      (map-set stakes 
        {user: tx-sender} 
        { amount: amount, unlock-height: (+ burn-block-height lock-period) })
      ERR-INVALID)
    (stx-transfer? amount tx-sender (var-get dao-treasury))))

(define-public (unstake)
  (let ((st (unwrap! (map-get? stakes {user: tx-sender}) ERR-INVALID)))
    (if (>= burn-block-height (get unlock-height st))
        (begin
          (map-delete stakes {user: tx-sender})
          (stx-transfer? (get amount st) (var-get dao-treasury) tx-sender)
        )
        ERR-INVALID)))

;; ---------------------------------------------------------
;; Subscription Payments
;; ---------------------------------------------------------

(define-public (subscribe (duration uint) (fee uint))
  (begin
    (asserts! (> duration u0) ERR-INVALID)
    (asserts! (> fee u0) ERR-INVALID)
    (asserts! (>= (stx-get-balance tx-sender) fee) ERR-INSUFFICIENT)
    (asserts! 
      (map-set subscriptions 
        {user: tx-sender} 
        { expiry: (+ burn-block-height duration) })
      ERR-INVALID)
    (stx-transfer? fee tx-sender (var-get dao-treasury))))

(define-read-only (is-subscribed (user principal))
  (let ((sub (map-get? subscriptions {user: user})))
    (match sub s (>= (get expiry s) burn-block-height) false)))

;; ---------------------------------------------------------
;; Auctions
;; ---------------------------------------------------------

(define-public (create-auction (end uint))
  (let ((auction-id (+ (var-get auction-counter) u1)))
    (begin
      (asserts! (> end burn-block-height) ERR-INVALID)
      (var-set auction-counter auction-id)
      (asserts! 
        (map-set auctions 
          {id: auction-id}
          { seller: tx-sender, highest-bidder: none, highest-bid: u0, end-block: end, active: true })
        ERR-INVALID)
      (ok auction-id)
    )
  ))

(define-public (bid (auction-id uint) (amount uint))
  (let ((a (unwrap! (map-get? auctions {id: auction-id}) ERR-INVALID)))
    (begin
      (asserts! (< burn-block-height (get end-block a)) ERR-INVALID)
      (asserts! (get active a) ERR-INVALID)
      (asserts! (> amount (get highest-bid a)) ERR-INVALID)
      (asserts! (>= (stx-get-balance tx-sender) amount) ERR-INSUFFICIENT)
      (asserts!
        (map-set auctions 
          {id: auction-id}
          (merge a {
            highest-bidder: (some tx-sender),
            highest-bid: amount
          }))
        ERR-INVALID)
      (ok true)
    )))

(define-public (finalize-auction (auction-id uint))
  (let ((a (unwrap! (map-get? auctions {id: auction-id}) ERR-INVALID)))
    (begin
      (asserts! (>= burn-block-height (get end-block a)) ERR-INVALID)
      (asserts! (get active a) ERR-INVALID)
      (asserts!
        (map-set auctions 
          {id: auction-id}
          (merge a { active: false }))
        ERR-INVALID)
      (match (get highest-bidder a)
        bidder (stx-transfer? (get highest-bid a) bidder (get seller a))
        (ok false))
    )))
