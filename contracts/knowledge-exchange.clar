(define-constant ERR_NOT_AUTHORIZED (err u100))
(define-constant ERR_PROBLEM_NOT_FOUND (err u101))
(define-constant ERR_SOLUTION_NOT_FOUND (err u102))
(define-constant ERR_INVALID_AMOUNT (err u103))
(define-constant ERR_ALREADY_SOLVED (err u104))
(define-constant ERR_INSUFFICIENT_BALANCE (err u105))
(define-constant ERR_INVALID_STATUS (err u106))
(define-constant ERR_SOLUTION_ALREADY_EXISTS (err u107))
(define-constant ERR_VOTING_CLOSED (err u108))

(define-constant STATUS_OPEN u0)
(define-constant STATUS_SOLVED u1)
(define-constant STATUS_CLOSED u2)

(define-data-var next-problem-id uint u1)
(define-data-var next-solution-id uint u1)
(define-data-var protocol-fee uint u50)

(define-map problems
  { problem-id: uint }
  {
    creator: principal,
    title: (string-ascii 100),
    description: (string-ascii 500),
    reward: uint,
    status: uint,
    created-at: uint,
    solved-by: (optional principal),
    solution-id: (optional uint)
  }
)

(define-map solutions
  { solution-id: uint }
  {
    problem-id: uint,
    solver: principal,
    description: (string-ascii 1000),
    created-at: uint,
    votes: uint,
    is-accepted: bool
  }
)

(define-map user-balances
  { user: principal }
  { balance: uint }
)

(define-map problem-solutions
  { problem-id: uint, solution-id: uint }
  { exists: bool }
)

(define-map solution-votes
  { solution-id: uint, voter: principal }
  { vote: bool }
)

(define-map user-reputation
  { user: principal }
  { score: uint }
)

(define-private (get-user-balance (user principal))
  (default-to u0 (get balance (map-get? user-balances { user: user })))
)

(define-private (set-user-balance (user principal) (amount uint))
  (map-set user-balances { user: user } { balance: amount })
)

(define-private (add-to-balance (user principal) (amount uint))
  (let ((current-balance (get-user-balance user)))
    (set-user-balance user (+ current-balance amount))
  )
)

(define-private (subtract-from-balance (user principal) (amount uint))
  (let ((current-balance (get-user-balance user)))
    (if (>= current-balance amount)
      (begin
        (set-user-balance user (- current-balance amount))
        (ok true)
      )
      ERR_INSUFFICIENT_BALANCE
    )
  )
)

(define-private (get-user-reputation (user principal))
  (default-to u0 (get score (map-get? user-reputation { user: user })))
)

(define-private (update-reputation (user principal) (points uint))
  (let ((current-score (get-user-reputation user)))
    (map-set user-reputation { user: user } { score: (+ current-score points) })
  )
)

(define-public (deposit (amount uint))
  (begin
    (try! (stx-transfer? amount tx-sender (as-contract tx-sender)))
    (add-to-balance tx-sender amount)
    (ok true)
  )
)

(define-public (withdraw (amount uint))
  (begin
    (try! (subtract-from-balance tx-sender amount))
    (try! (as-contract (stx-transfer? amount tx-sender tx-sender)))
    (ok true)
  )
)

(define-public (create-problem (title (string-ascii 100)) (description (string-ascii 500)) (reward uint))
  (let (
    (problem-id (var-get next-problem-id))
    (current-balance (get-user-balance tx-sender))
  )
    (asserts! (> reward u0) ERR_INVALID_AMOUNT)
    (asserts! (>= current-balance reward) ERR_INSUFFICIENT_BALANCE)
    (try! (subtract-from-balance tx-sender reward))
    (map-set problems
      { problem-id: problem-id }
      {
        creator: tx-sender,
        title: title,
        description: description,
        reward: reward,
        status: STATUS_OPEN,
        created-at: stacks-block-height,
        solved-by: none,
        solution-id: none
      }
    )
    (var-set next-problem-id (+ problem-id u1))
    (ok problem-id)
  )
)

(define-public (submit-solution (problem-id uint) (description (string-ascii 1000)))
  (let (
    (solution-id (var-get next-solution-id))
    (problem (unwrap! (map-get? problems { problem-id: problem-id }) ERR_PROBLEM_NOT_FOUND))
  )
    (asserts! (is-eq (get status problem) STATUS_OPEN) ERR_ALREADY_SOLVED)
    (asserts! (is-none (map-get? problem-solutions { problem-id: problem-id, solution-id: solution-id })) ERR_SOLUTION_ALREADY_EXISTS)
    (map-set solutions
      { solution-id: solution-id }
      {
        problem-id: problem-id,
        solver: tx-sender,
        description: description,
        created-at: stacks-block-height,
        votes: u0,
        is-accepted: false
      }
    )
    (map-set problem-solutions
      { problem-id: problem-id, solution-id: solution-id }
      { exists: true }
    )
    (var-set next-solution-id (+ solution-id u1))
    (update-reputation tx-sender u1)
    (ok solution-id)
  )
)

(define-public (vote-solution (solution-id uint) (upvote bool))
  (let (
    (solution (unwrap! (map-get? solutions { solution-id: solution-id }) ERR_SOLUTION_NOT_FOUND))
    (problem (unwrap! (map-get? problems { problem-id: (get problem-id solution) }) ERR_PROBLEM_NOT_FOUND))
    (existing-vote (map-get? solution-votes { solution-id: solution-id, voter: tx-sender }))
  )
    (asserts! (is-eq (get status problem) STATUS_OPEN) ERR_VOTING_CLOSED)
    (asserts! (not (is-eq tx-sender (get solver solution))) ERR_NOT_AUTHORIZED)
    (map-set solution-votes
      { solution-id: solution-id, voter: tx-sender }
      { vote: upvote }
    )
    (begin
      (if upvote
        (map-set solutions
          { solution-id: solution-id }
          (merge solution { votes: (+ (get votes solution) u1) })
        )
        true
      )
      (if upvote
        (update-reputation (get solver solution) u2)
        true
      )
    )
    (ok true)
  )
)

(define-public (accept-solution (problem-id uint) (solution-id uint))
  (let (
    (problem (unwrap! (map-get? problems { problem-id: problem-id }) ERR_PROBLEM_NOT_FOUND))
    (solution (unwrap! (map-get? solutions { solution-id: solution-id }) ERR_SOLUTION_NOT_FOUND))
    (fee (/ (* (get reward problem) (var-get protocol-fee)) u1000))
    (solver-reward (- (get reward problem) fee))
  )
    (asserts! (is-eq tx-sender (get creator problem)) ERR_NOT_AUTHORIZED)
    (asserts! (is-eq (get status problem) STATUS_OPEN) ERR_ALREADY_SOLVED)
    (asserts! (is-eq (get problem-id solution) problem-id) ERR_SOLUTION_NOT_FOUND)
    (map-set problems
      { problem-id: problem-id }
      (merge problem {
        status: STATUS_SOLVED,
        solved-by: (some (get solver solution)),
        solution-id: (some solution-id)
      })
    )
    (map-set solutions
      { solution-id: solution-id }
      (merge solution { is-accepted: true })
    )
    (add-to-balance (get solver solution) solver-reward)
    (add-to-balance (as-contract tx-sender) fee)
    (update-reputation (get solver solution) u10)
    (update-reputation tx-sender u5)
    (ok true)
  )
)

(define-public (close-problem (problem-id uint))
  (let (
    (problem (unwrap! (map-get? problems { problem-id: problem-id }) ERR_PROBLEM_NOT_FOUND))
  )
    (asserts! (is-eq tx-sender (get creator problem)) ERR_NOT_AUTHORIZED)
    (asserts! (is-eq (get status problem) STATUS_OPEN) ERR_INVALID_STATUS)
    (map-set problems
      { problem-id: problem-id }
      (merge problem { status: STATUS_CLOSED })
    )
    (add-to-balance tx-sender (get reward problem))
    (ok true)
  )
)

(define-read-only (get-problem (problem-id uint))
  (map-get? problems { problem-id: problem-id })
)

(define-read-only (get-solution (solution-id uint))
  (map-get? solutions { solution-id: solution-id })
)

(define-read-only (get-user-balance-public (user principal))
  (get-user-balance user)
)

(define-read-only (get-user-reputation-public (user principal))
  (get-user-reputation user)
)

(define-read-only (get-next-problem-id)
  (var-get next-problem-id)
)

(define-read-only (get-next-solution-id)
  (var-get next-solution-id)
)

(define-read-only (get-protocol-fee)
  (var-get protocol-fee)
)

(define-read-only (has-voted (solution-id uint) (voter principal))
  (is-some (map-get? solution-votes { solution-id: solution-id, voter: voter }))
)

(define-read-only (get-vote (solution-id uint) (voter principal))
  (map-get? solution-votes { solution-id: solution-id, voter: voter })
)

(define-read-only (solution-exists-for-problem (problem-id uint) (solution-id uint))
  (is-some (map-get? problem-solutions { problem-id: problem-id, solution-id: solution-id }))
)