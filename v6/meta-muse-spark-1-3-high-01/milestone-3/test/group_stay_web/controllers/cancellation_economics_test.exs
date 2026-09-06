defmodule GroupStayWeb.CancellationEconomicsTest do
  use GroupStayWeb.ConnCase, async: false

  defp post_batch(conn, operations) do
    post(conn, "/api/v1/partner-batches", %{operations: operations})
  end

  defp open_op(group_id, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-open-#{group_id}",
        "type" => "open_group",
        "occurred_on" => "2026-10-03",
        "group_id" => group_id,
        "guest_id" => "guest-22",
        "property_id" => "ams-canal",
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-13",
        "rate_plan" => "flexible",
        "rooms" => [
          %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
          %{"room_id" => "room-b", "nightly_rate_cents" => 17_500}
        ]
      },
      overrides
    )
  end

  defp pay_op(op_id, group_id, amount, extra \\ %{}) do
    Map.merge(
      %{
        "operation_id" => op_id,
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => group_id,
        "amount_cents" => amount
      },
      extra
    )
  end

  defp credit_op(op_id, group_id, amount, extra \\ %{}) do
    Map.merge(
      %{
        "operation_id" => op_id,
        "type" => "apply_hotel_credit",
        "occurred_on" => "2026-10-05",
        "group_id" => group_id,
        "amount_cents" => amount
      },
      extra
    )
  end

  defp cancel_op(op_id, group_id, occurred_on, extra \\ %{}) do
    Map.merge(
      %{
        "operation_id" => op_id,
        "type" => "cancel_group",
        "occurred_on" => occurred_on,
        "group_id" => group_id
      },
      extra
    )
  end

  test "policy versions and refundable_until on group reads", %{conn: conn} do
    # booked 2026 -> flex-14, refundable_until = arrival - 14
    conn = post_batch(conn, [open_op("g-flex14")])
    assert %{"results" => [%{"status" => "applied"}]} = json_response(conn, 200)
    c = get(build_conn(), "/api/v1/groups/g-flex14")
    assert %{"data" => d} = json_response(c, 200)
    assert d["policy_version"] == "flex-14"
    assert d["refundable_until"] == "2026-11-26"
    assert d["cash_paid_cents"] == 0
    assert d["credit_paid_cents"] == 0

    # booked 2027 -> flex-30
    c =
      post_batch(build_conn(), [
        open_op("g-flex30", %{"operation_id" => "op-f30", "occurred_on" => "2027-02-01"})
      ])

    assert %{"results" => [%{"status" => "applied"}]} = json_response(c, 200)
    c = get(build_conn(), "/api/v1/groups/g-flex30")
    assert %{"data" => d30} = json_response(c, 200)
    assert d30["policy_version"] == "flex-30"
    assert d30["refundable_until"] == "2026-11-10"

    # cutoff date exactly 2027-01-01 -> flex-30
    c =
      post_batch(build_conn(), [
        open_op("g-cutoff", %{"operation_id" => "op-cut", "occurred_on" => "2027-01-01"})
      ])

    assert %{"results" => [%{"status" => "applied"}]} = json_response(c, 200)
    c = get(build_conn(), "/api/v1/groups/g-cutoff")
    assert %{"data" => dc} = json_response(c, 200)
    assert dc["policy_version"] == "flex-30"

    # advance purchase
    c =
      post_batch(build_conn(), [
        open_op("g-adv", %{"operation_id" => "op-adv", "rate_plan" => "advance_purchase"})
      ])

    assert %{"results" => [%{"status" => "applied"}]} = json_response(c, 200)
    c = get(build_conn(), "/api/v1/groups/g-adv")
    assert %{"data" => da} = json_response(c, 200)
    assert da["policy_version"] == "advance-nonrefundable"
    assert da["refundable_until"] == nil
  end

  test "flex-30 cancellation window enforced; reschedule keeps policy and returns fields", %{
    conn: conn
  } do
    conn =
      post_batch(conn, [
        open_op("g-win", %{"operation_id" => "op-w", "occurred_on" => "2027-02-01"})
      ])

    assert json_response(conn, 200)

    c = post_batch(build_conn(), [pay_op("op-wp", "g-win", 5_000)])
    assert json_response(c, 200)

    # arrival 2026-12-10; cancel 2026-11-20 is 20 days -> non-refundable under flex-30
    c = post_batch(build_conn(), [cancel_op("op-wc1", "g-win", "2026-11-20")])
    assert %{"results" => [r]} = json_response(c, 200)
    assert r["refunded_cents"] == 0
    assert r["retained_cents"] == 5_000

    # need fresh group for reschedule check
    c = post_batch(build_conn(), [open_op("g-move2", %{"operation_id" => "op-m"})])
    assert json_response(c, 200)

    c =
      post_batch(build_conn(), [
        %{
          "operation_id" => "op-rs",
          "type" => "reschedule_group",
          "occurred_on" => "2026-10-05",
          "group_id" => "g-move2",
          "new_arrival_on" => "2026-12-12"
        }
      ])

    assert %{"results" => [rr]} = json_response(c, 200)
    assert rr["status"] == "applied"
    assert rr["new_arrival_on"] == "2026-12-12"
    assert rr["new_departure_on"] == "2026-12-15"
    assert rr["policy_version"] == "flex-14"
    assert rr["refundable_until"] == "2026-11-28"

    # 30-day boundary: flex-30 cancel exactly 30 days before arrival is refundable
    c =
      post_batch(build_conn(), [
        open_op("g-30b", %{"operation_id" => "op-30b", "occurred_on" => "2027-02-01"})
      ])

    assert json_response(c, 200)
    c = post_batch(build_conn(), [pay_op("op-30p", "g-30b", 2_000)])
    assert json_response(c, 200)
    # arrival 12-10 minus 30 = 11-10
    c = post_batch(build_conn(), [cancel_op("op-30c", "g-30b", "2026-11-10")])
    assert %{"results" => [r30]} = json_response(c, 200)
    assert r30["refunded_cents"] == 2_000
    assert r30["retained_cents"] == 0

    # rescheduling never moves policy: old flex-14 booking keeps 14-day window after move
    c =
      post_batch(build_conn(), [
        open_op("g-oldmove", %{
          "operation_id" => "op-om",
          "occurred_on" => "2026-05-01",
          "arrival_on" => "2026-12-10",
          "departure_on" => "2026-12-13"
        })
      ])

    assert json_response(c, 200)

    c =
      post_batch(build_conn(), [
        %{
          "operation_id" => "op-om-rs",
          "type" => "reschedule_group",
          "occurred_on" => "2026-10-05",
          "group_id" => "g-oldmove",
          "new_arrival_on" => "2027-03-10"
        }
      ])

    assert %{"results" => [rm]} = json_response(c, 200)
    assert rm["policy_version"] == "flex-14"
    assert rm["refundable_until"] == "2027-02-24"

    c2 = get(build_conn(), "/api/v1/groups/g-oldmove")
    assert %{"data" => dm} = json_response(c2, 200)
    assert dm["policy_version"] == "flex-14"
    assert dm["refundable_until"] == "2027-02-24"
  end

  test "cancel with hotel_credit issues 110% lot, moves ledger, rejects non-refundable", %{
    conn: conn
  } do
    conn = post_batch(conn, [open_op("g-hc1")])
    assert json_response(conn, 200)
    c = post_batch(build_conn(), [pay_op("op-hcpay", "g-hc1", 5_000)])
    assert json_response(c, 200)

    c =
      post_batch(build_conn(), [
        cancel_op("op-hccancel", "g-hc1", "2026-11-20", %{"refund_method" => "hotel_credit"})
      ])

    assert %{"results" => [r]} = json_response(c, 200)
    assert r["status"] == "applied"
    assert r["refunded_cents"] == 0
    assert r["retained_cents"] == 0
    # 5000 + 10% = 5500
    assert r["credit_issued_cents"] == 5_500

    # credit endpoint: available 5500, expiry 365 days after cancellation +1 day => 2027-11-21
    c = get(build_conn(), "/api/v1/guests/guest-22/credit", %{on: "2026-11-21"})
    assert %{"data" => cd} = json_response(c, 200)
    assert cd["guest_id"] == "guest-22"
    assert cd["available_cents"] == 5_500

    assert [%{"source_operation_id" => "op-hccancel", "remaining_cents" => 5_500} = lot] =
             cd["lots"]

    assert lot["expires_on"] == "2027-11-21"

    # ledger: on the expiry date the lot is already expired
    lc = get(build_conn(), "/api/v1/ledger", %{on: "2026-11-20"})
    assert %{"data" => ledger} = json_response(lc, 200)
    assert ledger["cash_held_cents"] == 0
    assert ledger["cash_refunded_cents"] == 0
    assert ledger["cash_retained_cents"] == 0
    assert ledger["cash_converted_to_credit_cents"] == 5_000
    assert ledger["credit_liability_cents"] == 5_500

    lc = get(build_conn(), "/api/v1/ledger", %{on: "2027-11-21"})
    assert %{"data" => %{"credit_liability_cents" => 0}} = json_response(lc, 200)

    # non-refundable + hotel_credit rejected, group stays active
    c = post_batch(build_conn(), [open_op("g-hc-late", %{"operation_id" => "op-hcl"})])
    assert json_response(c, 200)
    c = post_batch(build_conn(), [pay_op("op-hclpay", "g-hc-late", 1_000)])
    assert json_response(c, 200)

    c =
      post_batch(build_conn(), [
        cancel_op("op-hclcancel", "g-hc-late", "2026-12-01", %{"refund_method" => "hotel_credit"})
      ])

    assert %{"results" => [rej]} = json_response(c, 200)
    assert rej["status"] == "rejected"
    assert rej["code"] == "refund_method_not_available"

    c = get(build_conn(), "/api/v1/groups/g-hc-late")
    assert %{"data" => dg} = json_response(c, 200)
    assert dg["status"] == "active"
  end

  test "rounding bonus half-cent upward and expiry dates", %{conn: conn} do
    # cash 5 -> bonus 0.5 -> 1; issued 6
    conn = post_batch(conn, [open_op("g-tiny", %{"operation_id" => "op-tiny"})])
    assert json_response(conn, 200)
    c = post_batch(build_conn(), [pay_op("op-tinypay", "g-tiny", 5)])
    assert json_response(c, 200)

    c =
      post_batch(build_conn(), [
        cancel_op("op-tinycancel", "g-tiny", "2026-11-20", %{"refund_method" => "hotel_credit"})
      ])

    assert %{"results" => [r]} = json_response(c, 200)
    assert r["credit_issued_cents"] == 6

    # available through date 365 days after cancellation, expires following day
    # cancel 2026-11-20 + 365 = 2027-11-20 available; expires_on 2027-11-21
    c = get(build_conn(), "/api/v1/guests/guest-22/credit", %{on: "2027-11-20"})
    assert %{"data" => %{"available_cents" => 6}} = json_response(c, 200)
    c = get(build_conn(), "/api/v1/guests/guest-22/credit", %{on: "2027-11-21"})
    assert %{"data" => %{"available_cents" => 0, "lots" => []}} = json_response(c, 200)
    c = get(build_conn(), "/api/v1/guests/guest-22/credit", %{on: "2027-11-22"})
    assert %{"data" => %{"available_cents" => 0, "lots" => []}} = json_response(c, 200)

    lc = get(build_conn(), "/api/v1/ledger", %{on: "2027-11-21"})
    assert %{"data" => %{"credit_liability_cents" => 0}} = json_response(lc, 200)
  end

  test "apply credit consumes earliest expiry, respects outstanding and insufficient", %{
    conn: conn
  } do
    # Build two lots for a dedicated guest via two cancellations
    conn =
      post_batch(conn, [
        open_op("g-src1", %{
          "operation_id" => "op-src1",
          "guest_id" => "guest-credit",
          "rooms" => [%{"room_id" => "r1", "nightly_rate_cents" => 10_000}],
          "arrival_on" => "2026-12-10",
          "departure_on" => "2026-12-11"
        })
      ])

    assert json_response(conn, 200)
    # deposit for 10000 lodging flexible = 2000
    c =
      post_batch(build_conn(), [
        pay_op("op-src1pay", "g-src1", 2_000, %{"occurred_on" => "2026-10-04"})
      ])

    # pay op helper defaults occurred_on; override group only. fix payload group guest? pay uses group.
    assert json_response(c, 200)

    c =
      post_batch(build_conn(), [
        cancel_op("op-lot-a", "g-src1", "2026-11-01", %{"refund_method" => "hotel_credit"})
      ])

    assert %{"results" => [%{"credit_issued_cents" => 2_200}]} = json_response(c, 200)
    # lot A expires 2027-11-02

    c =
      post_batch(build_conn(), [
        open_op("g-src2", %{
          "operation_id" => "op-src2",
          "guest_id" => "guest-credit",
          "rooms" => [%{"room_id" => "r1", "nightly_rate_cents" => 10_000}],
          "arrival_on" => "2026-12-10",
          "departure_on" => "2026-12-11"
        })
      ])

    assert json_response(c, 200)

    c =
      post_batch(build_conn(), [
        pay_op("op-src2pay", "g-src2", 2_000, %{"occurred_on" => "2026-10-04"})
      ])

    assert json_response(c, 200)

    c =
      post_batch(build_conn(), [
        cancel_op("op-lot-b", "g-src2", "2026-11-10", %{"refund_method" => "hotel_credit"})
      ])

    assert %{"results" => [%{"credit_issued_cents" => 2_200}]} = json_response(c, 200)
    # lot B expires 2027-11-11

    # target group needs 2000 deposit
    c =
      post_batch(build_conn(), [
        open_op("g-use", %{
          "operation_id" => "op-use",
          "guest_id" => "guest-credit",
          "rooms" => [%{"room_id" => "r1", "nightly_rate_cents" => 10_000}],
          "arrival_on" => "2026-12-10",
          "departure_on" => "2026-12-11"
        })
      ])

    assert json_response(c, 200)

    # insufficient when asking more than available outstanding? outstanding 2000, available 4400.
    # request 2000 -> consumes earliest (lot A 2200 -> 200 left)
    c = post_batch(build_conn(), [credit_op("op-apply1", "g-use", 2_000)])
    assert %{"results" => [r1]} = json_response(c, 200)
    assert r1["status"] == "applied"
    assert r1["amount_cents"] == 2_000
    assert r1["outstanding_deposit_cents"] == 0

    # liability counts applied credit too: 200 consumed from lot A + 2000 applied = 4400
    lc = get(build_conn(), "/api/v1/ledger", %{on: "2026-11-15"})
    assert %{"data" => %{"credit_liability_cents" => 4_400}} = json_response(lc, 200)

    c = get(build_conn(), "/api/v1/groups/g-use")
    assert %{"data" => du} = json_response(c, 200)
    assert du["cash_paid_cents"] == 0
    assert du["credit_paid_cents"] == 2_000
    assert du["deposit_paid_cents"] == 2_000

    c = get(build_conn(), "/api/v1/guests/guest-credit/credit", %{on: "2026-11-15"})
    assert %{"data" => avail} = json_response(c, 200)
    # lot A has 200 left, lot B full 2200 => 2400, ordered by expiry
    assert avail["available_cents"] == 2_400
    assert Enum.map(avail["lots"], & &1["source_operation_id"]) == ["op-lot-a", "op-lot-b"]

    # cannot exceed outstanding
    c = post_batch(build_conn(), [credit_op("op-apply2", "g-use", 100)])
    assert %{"results" => [%{"code" => "payment_exceeds_outstanding"}]} = json_response(c, 200)

    # insufficient credit on fresh group needing 2000 but only 2400 available -> request 2000 ok; use new guest
    c =
      post_batch(build_conn(), [
        open_op("g-poor", %{
          "operation_id" => "op-poor",
          "guest_id" => "guest-poor",
          "rooms" => [%{"room_id" => "r1", "nightly_rate_cents" => 10_000}],
          "arrival_on" => "2026-12-10",
          "departure_on" => "2026-12-11"
        })
      ])

    assert json_response(c, 200)
    c = post_batch(build_conn(), [credit_op("op-poor-apply", "g-poor", 100)])
    assert %{"results" => [%{"code" => "insufficient_credit"}]} = json_response(c, 200)

    # invalid amount
    c = post_batch(build_conn(), [credit_op("op-bad-amt", "g-poor", 0)])
    assert %{"results" => [%{"code" => "invalid_amount"}]} = json_response(c, 200)

    # missing group
    c = post_batch(build_conn(), [credit_op("op-no-group", "no-such", 100)])
    assert %{"results" => [%{"code" => "group_not_found"}]} = json_response(c, 200)
  end

  test "refundable cancel restores applied credit to original lots without second bonus", %{
    conn: conn
  } do
    # source lot: guest-mix pays 2000 cash -> converts to 2200 credit
    conn =
      post_batch(conn, [
        open_op("g-msrc", %{
          "operation_id" => "op-msrc",
          "guest_id" => "guest-mix",
          "rooms" => [%{"room_id" => "r1", "nightly_rate_cents" => 10_000}],
          "arrival_on" => "2026-12-10",
          "departure_on" => "2026-12-11"
        })
      ])

    assert json_response(conn, 200)
    c = post_batch(build_conn(), [pay_op("op-msrcpay", "g-msrc", 2_000)])
    assert json_response(c, 200)

    c =
      post_batch(build_conn(), [
        cancel_op("op-mix-lot", "g-msrc", "2026-11-01", %{"refund_method" => "hotel_credit"})
      ])

    assert %{"results" => [%{"credit_issued_cents" => 2_200}]} = json_response(c, 200)

    # target: deposit 2000; pay 1000 cash + 1000 credit
    c =
      post_batch(build_conn(), [
        open_op("g-mtgt", %{
          "operation_id" => "op-mtgt",
          "guest_id" => "guest-mix",
          "rooms" => [%{"room_id" => "r1", "nightly_rate_cents" => 10_000}],
          "arrival_on" => "2027-01-10",
          "departure_on" => "2027-01-11"
        })
      ])

    assert json_response(c, 200)
    c = post_batch(build_conn(), [pay_op("op-mtgtpay", "g-mtgt", 1_000)])
    assert json_response(c, 200)
    c = post_batch(build_conn(), [credit_op("op-mtgtcr", "g-mtgt", 1_000)])
    assert %{"results" => [%{"status" => "applied"}]} = json_response(c, 200)

    c = get(build_conn(), "/api/v1/groups/g-mtgt")

    assert %{"data" => %{"cash_paid_cents" => 1_000, "credit_paid_cents" => 1_000}} =
             json_response(c, 200)

    # refundable cancel with cash: cash 1000 refunded, credit 1000 restored, no new lot
    c = post_batch(build_conn(), [cancel_op("op-mtgt-cancel", "g-mtgt", "2026-12-01")])
    assert %{"results" => [r]} = json_response(c, 200)
    assert r["refunded_cents"] == 1_000
    assert r["retained_cents"] == 0

    c = get(build_conn(), "/api/v1/guests/guest-mix/credit", %{on: "2026-12-02"})
    assert %{"data" => cd} = json_response(c, 200)
    assert cd["available_cents"] == 2_200
    assert [%{"remaining_cents" => 2_200, "source_operation_id" => "op-mix-lot"}] = cd["lots"]

    lc = get(build_conn(), "/api/v1/ledger", %{on: "2026-12-02"})
    assert %{"data" => ledger} = json_response(lc, 200)
    # converted 2000 (from source), refunded 1000, liability 2200
    assert ledger["cash_converted_to_credit_cents"] == 2_000
    assert ledger["cash_refunded_cents"] == 1_000
    assert ledger["credit_liability_cents"] == 2_200
  end

  test "refundable cancel with hotel_credit converts cash and restores credit", %{conn: conn} do
    conn =
      post_batch(conn, [
        open_op("g-csrc", %{
          "operation_id" => "op-csrc",
          "guest_id" => "guest-conv",
          "rooms" => [%{"room_id" => "r1", "nightly_rate_cents" => 10_000}],
          "arrival_on" => "2026-12-10",
          "departure_on" => "2026-12-11"
        })
      ])

    assert json_response(conn, 200)
    c = post_batch(build_conn(), [pay_op("op-csrcpay", "g-csrc", 2_000)])
    assert json_response(c, 200)

    c =
      post_batch(build_conn(), [
        cancel_op("op-conv-lot", "g-csrc", "2026-11-01", %{"refund_method" => "hotel_credit"})
      ])

    assert json_response(c, 200)

    c =
      post_batch(build_conn(), [
        open_op("g-ctgt", %{
          "operation_id" => "op-ctgt",
          "guest_id" => "guest-conv",
          "rooms" => [%{"room_id" => "r1", "nightly_rate_cents" => 10_000}],
          "arrival_on" => "2027-01-10",
          "departure_on" => "2027-01-11"
        })
      ])

    assert json_response(c, 200)
    c = post_batch(build_conn(), [pay_op("op-ctgtpay", "g-ctgt", 1_000)])
    assert json_response(c, 200)
    c = post_batch(build_conn(), [credit_op("op-ctgtcr", "g-ctgt", 1_000)])
    assert json_response(c, 200)

    # refundable cancel choosing hotel_credit: cash 1000 -> 1100 new lot; credit 1000 restored
    c =
      post_batch(build_conn(), [
        cancel_op("op-ctgt-cancel", "g-ctgt", "2026-12-01", %{"refund_method" => "hotel_credit"})
      ])

    assert %{"results" => [r]} = json_response(c, 200)
    assert r["refunded_cents"] == 0
    assert r["retained_cents"] == 0
    assert r["credit_issued_cents"] == 1_100

    c = get(build_conn(), "/api/v1/guests/guest-conv/credit", %{on: "2026-12-02"})
    assert %{"data" => cd} = json_response(c, 200)
    # original lot restored to 2200 + new 1100 = 3300
    assert cd["available_cents"] == 3_300

    lc = get(build_conn(), "/api/v1/ledger", %{on: "2026-12-02"})
    assert %{"data" => ledger} = json_response(lc, 200)
    assert ledger["cash_converted_to_credit_cents"] == 3_000
    assert ledger["credit_liability_cents"] == 3_300
  end

  test "non-refundable cancel consumes applied credit and retains cash", %{conn: conn} do
    conn =
      post_batch(conn, [
        open_op("g-nsrc", %{
          "operation_id" => "op-nsrc",
          "guest_id" => "guest-nr",
          "rooms" => [%{"room_id" => "r1", "nightly_rate_cents" => 10_000}],
          "arrival_on" => "2026-12-10",
          "departure_on" => "2026-12-11"
        })
      ])

    assert json_response(conn, 200)
    c = post_batch(build_conn(), [pay_op("op-nsrcpay", "g-nsrc", 2_000)])
    assert json_response(c, 200)

    c =
      post_batch(build_conn(), [
        cancel_op("op-nr-lot", "g-nsrc", "2026-11-01", %{"refund_method" => "hotel_credit"})
      ])

    assert json_response(c, 200)

    c =
      post_batch(build_conn(), [
        open_op("g-ntgt", %{
          "operation_id" => "op-ntgt",
          "guest_id" => "guest-nr",
          "rooms" => [%{"room_id" => "r1", "nightly_rate_cents" => 10_000}],
          "arrival_on" => "2026-12-10",
          "departure_on" => "2026-12-11"
        })
      ])

    assert json_response(c, 200)
    c = post_batch(build_conn(), [pay_op("op-ntgtpay", "g-ntgt", 1_000)])
    assert json_response(c, 200)
    c = post_batch(build_conn(), [credit_op("op-ntgtcr", "g-ntgt", 1_000)])
    assert json_response(c, 200)

    # late cancel -> non-refundable
    c = post_batch(build_conn(), [cancel_op("op-ntgt-cancel", "g-ntgt", "2026-12-05")])
    assert %{"results" => [r]} = json_response(c, 200)
    assert r["refunded_cents"] == 0
    assert r["retained_cents"] == 1_000

    c = get(build_conn(), "/api/v1/guests/guest-nr/credit", %{on: "2026-12-06"})
    assert %{"data" => cd} = json_response(c, 200)
    # lot was 2200, 1000 consumed -> 1200 left
    assert cd["available_cents"] == 1_200

    lc = get(build_conn(), "/api/v1/ledger", %{on: "2026-12-06"})
    assert %{"data" => ledger} = json_response(lc, 200)
    assert ledger["cash_retained_cents"] == 1_000
    assert ledger["credit_liability_cents"] == 1_200
  end

  test "expired restore reduces liability and is not available; expiry evaluated on occurred_on",
       %{
         conn: conn
       } do
    conn =
      post_batch(conn, [
        open_op("g-esrc", %{
          "operation_id" => "op-esrc",
          "guest_id" => "guest-exp",
          "rooms" => [%{"room_id" => "r1", "nightly_rate_cents" => 10_000}],
          "arrival_on" => "2026-12-10",
          "departure_on" => "2026-12-11"
        })
      ])

    assert json_response(conn, 200)
    c = post_batch(build_conn(), [pay_op("op-esrcpay", "g-esrc", 2_000)])
    assert json_response(c, 200)

    c =
      post_batch(build_conn(), [
        cancel_op("op-exp-lot", "g-esrc", "2026-01-10", %{"refund_method" => "hotel_credit"})
      ])

    assert json_response(c, 200)
    # lot expires 2027-01-11

    c =
      post_batch(build_conn(), [
        open_op("g-etgt", %{
          "operation_id" => "op-etgt",
          "guest_id" => "guest-exp",
          "rooms" => [%{"room_id" => "r1", "nightly_rate_cents" => 10_000}],
          "arrival_on" => "2026-06-10",
          "departure_on" => "2026-06-11"
        })
      ])

    assert json_response(c, 200)
    # apply while unexpired (occurred 2026-10-05? credit_op default 2026-10-05; need earlier)
    c =
      post_batch(build_conn(), [
        credit_op("op-exp-apply", "g-etgt", 2_000, %{"occurred_on" => "2026-05-01"})
      ])

    assert %{"results" => [%{"status" => "applied"}]} = json_response(c, 200)

    # cancel refundable but after lot expiry: arrival 06-10, cancel 05-20 (21 days, flex-14 refundable)
    # lot expiry 2027-01-11 is past on 2027? no - need cancel after expiry. Use arrival 2027-06-10?
    # Instead cancel late enough: reschedule target arrival to 2027-03-01 then cancel 2027-02-01 (after expiry 2027-01-11)
    c =
      post_batch(build_conn(), [
        %{
          "operation_id" => "op-exp-rs",
          "type" => "reschedule_group",
          "occurred_on" => "2026-05-02",
          "group_id" => "g-etgt",
          "new_arrival_on" => "2027-03-01"
        }
      ])

    assert %{"results" => [%{"status" => "applied"}]} = json_response(c, 200)

    # cancel 2027-02-01: 28 days before 03-01 -> refundable (flex-14). Lot expired 2027-01-11.
    c = post_batch(build_conn(), [cancel_op("op-exp-cancel", "g-etgt", "2027-02-01")])
    assert %{"results" => [r]} = json_response(c, 200)
    assert r["refunded_cents"] == 0

    c = get(build_conn(), "/api/v1/guests/guest-exp/credit", %{on: "2027-02-02"})
    assert %{"data" => cd} = json_response(c, 200)
    assert cd["available_cents"] == 0
    assert cd["lots"] == []

    lc = get(build_conn(), "/api/v1/ledger", %{on: "2027-02-02"})
    assert %{"data" => ledger} = json_response(lc, 200)

    # restored amount expired immediately -> liability 0 (original lot fully consumed+restored-expired)
    assert ledger["credit_liability_cents"] == 0
  end

  test "credit apply uses occurred_on for expiry; revision contract", %{conn: conn} do
    conn =
      post_batch(conn, [
        open_op("g-xsrc", %{
          "operation_id" => "op-xsrc",
          "guest_id" => "guest-rev",
          "rooms" => [%{"room_id" => "r1", "nightly_rate_cents" => 10_000}],
          "arrival_on" => "2026-12-10",
          "departure_on" => "2026-12-11"
        })
      ])

    assert json_response(conn, 200)
    c = post_batch(build_conn(), [pay_op("op-xsrcpay", "g-xsrc", 2_000)])
    assert json_response(c, 200)

    c =
      post_batch(build_conn(), [
        cancel_op("op-xrev-lot", "g-xsrc", "2026-11-01", %{"refund_method" => "hotel_credit"})
      ])

    assert json_response(c, 200)
    # expires 2027-11-02

    c =
      post_batch(build_conn(), [
        open_op("g-xtgt", %{
          "operation_id" => "op-xtgt",
          "guest_id" => "guest-rev",
          "rooms" => [%{"room_id" => "r1", "nightly_rate_cents" => 10_000}],
          "arrival_on" => "2026-12-10",
          "departure_on" => "2026-12-11"
        })
      ])

    assert json_response(c, 200)

    # expired as of occurred_on -> insufficient
    c =
      post_batch(build_conn(), [
        credit_op("op-xlate", "g-xtgt", 500, %{"occurred_on" => "2027-12-01"})
      ])

    assert %{"results" => [%{"code" => "insufficient_credit"}]} = json_response(c, 200)

    # stale revision checked before insufficient
    c =
      post_batch(build_conn(), [
        credit_op("op-xstale", "g-xtgt", 500, %{
          "occurred_on" => "2027-12-01",
          "expected_revision" => 99
        })
      ])

    assert %{"results" => [r]} = json_response(c, 200)
    assert r["code"] == "stale_revision"
    assert r["expected_revision"] == 99
    assert r["actual_revision"] == 1

    # valid apply bumps revision
    c = post_batch(build_conn(), [credit_op("op-xok", "g-xtgt", 500)])
    assert %{"results" => [%{"status" => "applied", "revision" => 2}]} = json_response(c, 200)

    # cancel hotel_credit on non-refundable with stale revision -> stale first
    c =
      post_batch(build_conn(), [
        cancel_op("op-xcancel-stale", "g-xtgt", "2026-12-09", %{
          "refund_method" => "hotel_credit",
          "expected_revision" => 1
        })
      ])

    assert %{"results" => [%{"code" => "stale_revision"}]} = json_response(c, 200)

    # group_not_active for credit on cancelled
    c = post_batch(build_conn(), [cancel_op("op-xcancel", "g-xtgt", "2026-11-01")])
    assert %{"results" => [%{"status" => "applied"}]} = json_response(c, 200)
    c = post_batch(build_conn(), [credit_op("op-xafter", "g-xtgt", 100)])
    assert %{"results" => [%{"code" => "group_not_active"}]} = json_response(c, 200)
  end
end
