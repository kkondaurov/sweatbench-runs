defmodule GroupStayWeb.DurableOperationsTest do
  use GroupStayWeb.ConnCase

  alias GroupStay.{Operation, Repo}
  alias GroupStay.Operations

  import Ecto.Query

  @base_open %{
    "operation_id" => "op-open",
    "type" => "open_group",
    "occurred_on" => "2026-10-03",
    "group_id" => "group-81",
    "guest_id" => "guest-22",
    "property_id" => "ams-canal",
    "arrival_on" => "2026-12-10",
    "departure_on" => "2026-12-13",
    "rate_plan" => "flexible",
    "rooms" => [
      %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
      %{"room_id" => "room-b", "nightly_rate_cents" => 17_500}
    ]
  }

  defp post_batch(conn, operations) do
    resp = post(conn, "/api/v1/partner-batches", %{"operations" => operations})
    {resp, Jason.decode!(resp.resp_body)["results"]}
  end

  defp submit(conn, op) do
    {_resp, results} = post_batch(conn, [op])
    hd(results)
  end

  defp pay(conn, operation_id, amount_cents, extra \\ %{}) do
    Map.merge(
      %{
        "operation_id" => operation_id,
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81",
        "amount_cents" => amount_cents
      },
      extra
    )
    |> then(&submit(conn, &1))
  end

  defp operation(conn, operation_id) do
    resp = get(conn, "/api/v1/operations/#{operation_id}")
    {resp, Jason.decode!(resp.resp_body)}
  end

  describe "exact retries of applied operations" do
    test "return the stored result without touching domain state", %{conn: conn} do
      assert submit(conn, @base_open)["status"] == "applied"

      first = pay(conn, "op-pay", 10_000)
      assert first["revision"] == 2

      # An exact retry returns the identical result and applies nothing.
      assert pay(conn, "op-pay", 10_000) == first

      assert Repo.get_by(GroupStay.Group, group_id: "group-81").revision == 2

      # A later different payment proves the retry did not consume a revision.
      assert pay(conn, "op-pay-2", 100)["revision"] == 3
    end

    test "object key order does not matter", %{conn: conn} do
      original = submit(conn, @base_open)

      reordered =
        Jason.decode!("""
        {
          "guest_id": "guest-22",
          "rooms": [
            {"room_id": "room-a", "nightly_rate_cents": 15000},
            {"room_id": "room-b", "nightly_rate_cents": 17500}
          ],
          "operation_id": "op-open",
          "arrival_on": "2026-12-10",
          "property_id": "ams-canal",
          "type": "open_group",
          "rate_plan": "flexible",
          "occurred_on": "2026-10-03",
          "group_id": "group-81",
          "departure_on": "2026-12-13"
        }
        """)

      assert submit(conn, reordered) == original
    end

    test "array order remains significant", %{conn: conn} do
      submit(conn, @base_open)

      swapped = %{
        @base_open
        | "rooms" => [
            %{"room_id" => "room-b", "nightly_rate_cents" => 17_500},
            %{"room_id" => "room-a", "nightly_rate_cents" => 15_000}
          ]
      }

      assert submit(conn, swapped) == %{
               "operation_id" => "op-open",
               "status" => "rejected",
               "code" => "operation_id_conflict",
               "group_id" => "group-81"
             }

      # The conflict did not replace the original record.
      assert submit(conn, @base_open)["status"] == "applied"
    end
  end

  describe "identifier reuse with a different payload" do
    test "is rejected with operation_id_conflict and keeps the original record", %{conn: conn} do
      submit(conn, @base_open)

      first = pay(conn, "op-pay", 100)
      assert first["status"] == "applied"

      assert pay(conn, "op-pay", 200) == %{
               "operation_id" => "op-pay",
               "status" => "rejected",
               "code" => "operation_id_conflict",
               "group_id" => "group-81"
             }

      # The original record still replays the original result.
      assert pay(conn, "op-pay", 100) == first
      assert Repo.get_by(GroupStay.Group, group_id: "group-81").deposit_paid_cents == 100

      {resp, json} = operation(conn, "op-pay")
      assert resp.status == 200
      assert json == %{"data" => first}
    end
  end

  describe "rejected results are remembered" do
    test "a retry receives the original rejection even when it is now valid", %{conn: conn} do
      open_group = fn group_id, operation_id ->
        submit(conn, %{
          "operation_id" => operation_id,
          "type" => "open_group",
          "occurred_on" => "2026-06-01",
          "group_id" => group_id,
          "guest_id" => "guest-dup",
          "property_id" => "ams-canal",
          "arrival_on" => "2026-12-15",
          "departure_on" => "2026-12-18",
          "rate_plan" => "flexible",
          "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 10_000}]
        })
      end

      # The guest starts with one small credit lot worth 550.
      open_group.("group-refunded-1", "op-credit-source-1")

      submit(conn, %{
        "operation_id" => "op-credit-pay-1",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-06-02",
        "group_id" => "group-refunded-1",
        "amount_cents" => 500
      })

      submit(conn, %{
        "operation_id" => "op-credit-cancel-1",
        "type" => "cancel_group",
        "occurred_on" => "2026-06-10",
        "group_id" => "group-refunded-1",
        "refund_method" => "hotel_credit"
      })

      open_group.("group-to", "op-credit-target")

      credit_apply = %{
        "operation_id" => "op-credit-apply",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2027-01-10",
        "group_id" => "group-to",
        "amount_cents" => 1_000
      }

      rejected = submit(conn, credit_apply)
      assert rejected["code"] == "insufficient_credit"

      # A later cancellation funds the guest, so the same submission would now
      # apply - but the original rejection is replayed instead.
      open_group.("group-refunded-2", "op-credit-source-2")

      submit(conn, %{
        "operation_id" => "op-credit-pay-2",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-07-02",
        "group_id" => "group-refunded-2",
        "amount_cents" => 1_000
      })

      submit(conn, %{
        "operation_id" => "op-credit-cancel-2",
        "type" => "cancel_group",
        "occurred_on" => "2026-07-10",
        "group_id" => "group-refunded-2",
        "refund_method" => "hotel_credit"
      })

      assert submit(conn, credit_apply) == rejected
      assert Repo.get_by(GroupStay.Group, group_id: "group-to").revision == 1

      {resp, json} = operation(conn, "op-credit-apply")
      assert resp.status == 200
      assert json == %{"data" => rejected}
    end

    test "an exact retry of a stale operation returns the recorded revisions verbatim", %{
      conn: conn
    } do
      submit(conn, @base_open)

      submit(conn, %{
        "operation_id" => "op-bump",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81",
        "amount_cents" => 100
      })

      stale =
        submit(conn, %{
          "operation_id" => "op-stale",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-04",
          "group_id" => "group-81",
          "amount_cents" => 100,
          "expected_revision" => 1
        })

      assert stale == %{
               "operation_id" => "op-stale",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-81",
               "expected_revision" => 1,
               "actual_revision" => 2
             }

      # The group moves on, but the recorded stale details are returned as-is.
      pay(conn, "op-bump-2", 100)

      assert submit(conn, %{
               "operation_id" => "op-stale",
               "type" => "record_cash_payment",
               "occurred_on" => "2026-10-04",
               "group_id" => "group-81",
               "amount_cents" => 100,
               "expected_revision" => 1
             }) == stale

      # Correcting the expected revision is a different payload: conflict.
      assert submit(conn, %{
               "operation_id" => "op-stale",
               "type" => "record_cash_payment",
               "occurred_on" => "2026-10-04",
               "group_id" => "group-81",
               "amount_cents" => 100,
               "expected_revision" => 2
             }) == %{
               "operation_id" => "op-stale",
               "status" => "rejected",
               "code" => "operation_id_conflict",
               "group_id" => "group-81"
             }
    end
  end

  describe "batch retries" do
    test "replaying a whole batch returns identical results in order", %{conn: conn} do
      batch = [@base_open, %{"operation_id" => "op-bad", "type" => "mystery_op"}]

      {_resp, first} = post_batch(conn, batch)
      {_resp, second} = post_batch(conn, batch)

      assert first == second

      assert second == [
               %{
                 "operation_id" => "op-open",
                 "status" => "applied",
                 "group_id" => "group-81",
                 "deposit_due_cents" => 19_500,
                 "revision" => 1
               },
               %{
                 "operation_id" => "op-bad",
                 "status" => "rejected",
                 "code" => "invalid_operation"
               }
             ]

      # The rejected operation was remembered too.
      {resp, json} = operation(conn, "op-bad")
      assert resp.status == 200

      assert json == %{
               "data" => %{
                 "operation_id" => "op-bad",
                 "status" => "rejected",
                 "code" => "invalid_operation"
               }
             }
    end

    test "duplicate identifiers inside one batch replay the first record", %{conn: conn} do
      {_resp, results} = post_batch(conn, [@base_open, @base_open])

      assert [first, second] = results
      assert first == second
      assert first["status"] == "applied"

      assert Repo.get_by(GroupStay.Group, group_id: "group-81").revision == 1
    end

    test "duplicate identifiers with different payloads conflict inside one batch", %{conn: conn} do
      op_a = %{@base_open | "operation_id" => "op-dup-group"}

      op_b = %{
        op_a
        | "arrival_on" => "2027-01-01",
          "departure_on" => "2027-01-04"
      }

      {_resp, results} = post_batch(conn, [op_a, op_b])

      assert hd(results)["status"] == "applied"

      assert Enum.at(results, 1) == %{
               "operation_id" => "op-dup-group",
               "status" => "rejected",
               "code" => "operation_id_conflict",
               "group_id" => "group-81"
             }

      # The group was opened only once.
      assert Repo.get_by(GroupStay.Group, group_id: "group-81").revision == 1
    end
  end

  describe "GET /api/v1/operations/:operation_id" do
    test "returns the stored result and 404s for unknown identifiers", %{conn: conn} do
      result = submit(conn, @base_open)

      {resp, json} = operation(conn, "op-open")
      assert resp.status == 200
      assert json == %{"data" => result}

      {missing, json} = operation(conn, "op-unknown")
      assert missing.status == 404
      assert json == %{"error" => %{"code" => "operation_not_found"}}
    end
  end

  describe "the durable record" do
    test "keeps the type, the complete submitted content, and commit order", %{conn: conn} do
      submit(conn, @base_open)
      pay(conn, "op-pay-1", 100)
      submit(conn, %{"operation_id" => "op-mystery", "type" => "mystery_op"})

      records =
        from(o in Operation, order_by: o.id)
        |> Repo.all()
        |> Enum.map(&{&1.operation_id, &1.type, &1.payload, &1.result["status"]})

      assert records == [
               {"op-open", "open_group", @base_open, "applied"},
               {"op-pay-1", "record_cash_payment",
                %{
                  "operation_id" => "op-pay-1",
                  "type" => "record_cash_payment",
                  "occurred_on" => "2026-10-04",
                  "group_id" => "group-81",
                  "amount_cents" => 100
                }, "applied"},
               {"op-mystery", "mystery_op",
                %{"operation_id" => "op-mystery", "type" => "mystery_op"}, "rejected"}
             ]
    end

    test "an unexpected exception commits nothing and re-raises", %{conn: conn} do
      poisoned = %{
        "operation_id" => "op-poisoned",
        "type" => "open_group",
        "payload" => {:not, :json}
      }

      assert_raise Ecto.ChangeError, fn -> Operations.apply_all([poisoned]) end

      assert Repo.get_by(Operation, operation_id: "op-poisoned") == nil

      # The service keeps accepting operations afterwards.
      assert submit(conn, @base_open)["status"] == "applied"
    end
  end
end
