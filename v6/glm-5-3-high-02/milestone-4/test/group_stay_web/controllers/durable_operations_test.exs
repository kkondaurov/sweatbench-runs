defmodule GroupStayWeb.DurableOperationsTest do
  @moduledoc """
  Product request 03: durably idempotent partner operations.

  `operation_id` prevents an operation from being applied twice. The
  first submission is processed normally and remembered with its exact
  result; equivalent retries replay that result without touching domain
  state, while different payloads conflict. Records live in the database,
  committed in the same transaction as the domain changes they describe.
  """

  use GroupStayWeb.ConnCase, async: true

  alias GroupStay.PartnerOperations

  @occurred_on "2026-10-03"
  @arrival_on "2026-12-10"
  @departure_on "2026-12-13"

  defp open_operation(group_id, operation_id \\ nil) do
    %{
      "operation_id" => operation_id || "op-open-#{group_id}",
      "type" => "open_group",
      "occurred_on" => @occurred_on,
      "group_id" => group_id,
      "guest_id" => "guest-22",
      "property_id" => "ams-canal",
      "arrival_on" => @arrival_on,
      "departure_on" => @departure_on,
      "rate_plan" => "flexible",
      "rooms" => [
        %{"room_id" => "room-a", "nightly_rate_cents" => 15000},
        %{"room_id" => "room-b", "nightly_rate_cents" => 17500}
      ]
    }
  end

  defp payment_operation(group_id, amount_cents, operation_id) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => @occurred_on,
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }
  end

  defp submit!(conn, operations) do
    conn = post(conn, "/api/v1/partner-batches", %{"operations" => operations})
    assert conn.status == 200
    json_response(conn, 200)["results"]
  end

  defp open_group!(conn, group_id) do
    [result] = submit!(conn, [open_operation(group_id)])
    assert result["status"] == "applied", inspect(result)
    result
  end

  defp group_data(conn, group_id) do
    conn = get(conn, "/api/v1/groups/#{group_id}")
    assert conn.status == 200
    json_response(conn, 200)["data"]
  end

  defp operation_data(conn, operation_id) do
    conn = get(conn, "/api/v1/operations/#{operation_id}")
    assert conn.status == 200
    json_response(conn, 200)["data"]
  end

  describe "retries of applied operations" do
    test "an identical retry returns the exact original result without reapplying" do
      conn = build_conn()
      open_group!(conn, "g-retry")

      assert [first] = submit!(conn, [payment_operation("g-retry", 5000, "op-pay-retry")])

      assert [retry] = submit!(conn, [payment_operation("g-retry", 5000, "op-pay-retry")])
      assert retry == first

      data = group_data(conn, "g-retry")
      assert data["deposit_paid_cents"] == 5000
      assert data["revision"] == 2
    end

    test "a retry returns the stored result even after the group moved on" do
      conn = build_conn()
      open_group!(conn, "g-moved-on")

      assert [pay] = submit!(conn, [payment_operation("g-moved-on", 5000, "op-pay-moved-on")])
      assert pay["revision"] == 2

      # Cancel the group: a fresh payment would be group_not_active.
      [cancel] =
        submit!(conn, [
          %{
            "operation_id" => "op-cancel-g-moved-on",
            "type" => "cancel_group",
            "occurred_on" => @occurred_on,
            "group_id" => "g-moved-on"
          }
        ])

      assert cancel["status"] == "applied"

      # The retry replays the stored result verbatim, revision included.
      assert [retry] = submit!(conn, [payment_operation("g-moved-on", 5000, "op-pay-moved-on")])
      assert retry == pay
      assert retry["revision"] == 2

      assert group_data(conn, "g-moved-on")["revision"] == 3
    end

    test "object key order is irrelevant, including in nested objects" do
      conn = build_conn()

      first_json =
        Jason.encode!(%{
          "operations" => [
            %{
              "operation_id" => "op-order",
              "type" => "open_group",
              "occurred_on" => @occurred_on,
              "group_id" => "g-order-keys",
              "guest_id" => "guest-22",
              "property_id" => "ams-canal",
              "arrival_on" => @arrival_on,
              "departure_on" => @departure_on,
              "rate_plan" => "flexible",
              "rooms" => [
                %{"room_id" => "room-a", "nightly_rate_cents" => 15000},
                %{"room_id" => "room-b", "nightly_rate_cents" => 17500}
              ]
            }
          ]
        })

      retry_json =
        Jason.encode!(%{
          "operations" => [
            %{
              "rooms" => [
                %{"nightly_rate_cents" => 15000, "room_id" => "room-a"},
                %{"nightly_rate_cents" => 17500, "room_id" => "room-b"}
              ],
              "rate_plan" => "flexible",
              "departure_on" => @departure_on,
              "arrival_on" => @arrival_on,
              "property_id" => "ams-canal",
              "guest_id" => "guest-22",
              "group_id" => "g-order-keys",
              "occurred_on" => @occurred_on,
              "type" => "open_group",
              "operation_id" => "op-order"
            }
          ]
        })

      post_first =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> post("/api/v1/partner-batches", first_json)

      assert post_first.status == 200
      first = hd(json_response(post_first, 200)["results"])
      assert first["status"] == "applied"

      post_retry =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> post("/api/v1/partner-batches", retry_json)

      assert post_retry.status == 200
      assert hd(json_response(post_retry, 200)["results"]) == first

      assert group_data(conn, "g-order-keys")["revision"] == 1
    end

    test "array order and values remain significant" do
      conn = build_conn()

      assert [first] = submit!(conn, [open_operation("g-array-order", "op-array")])
      assert first["status"] == "applied"

      # The same rooms in a different order are a different payload.
      reordered =
        open_operation("g-array-order", "op-array")
        |> Map.put("rooms", [
          %{"room_id" => "room-b", "nightly_rate_cents" => 17500},
          %{"room_id" => "room-a", "nightly_rate_cents" => 15000}
        ])

      assert [conflict] = submit!(conn, [reordered])
      assert conflict["status"] == "rejected"
      assert conflict["code"] == "operation_id_conflict"
      assert conflict["operation_id"] == "op-array"

      assert group_data(conn, "g-array-order")["revision"] == 1
    end

    test "a duplicate operation_id within one batch is applied at most once" do
      conn = build_conn()
      open_group!(conn, "g-in-batch")

      assert [first, second] =
               submit!(conn, [
                 payment_operation("g-in-batch", 5000, "op-dup"),
                 payment_operation("g-in-batch", 5000, "op-dup")
               ])

      assert second == first
      assert first["status"] == "applied"
      assert first["revision"] == 2

      assert group_data(conn, "g-in-batch")["deposit_paid_cents"] == 5000
      assert group_data(conn, "g-in-batch")["revision"] == 2
    end
  end

  describe "retries of rejected operations" do
    test "a rejected result is remembered and replayed verbatim" do
      conn = build_conn()
      open_group!(conn, "g-rejected")

      assert [first] =
               submit!(conn, [payment_operation("g-rejected", 25_000, "op-over")])

      assert first["status"] == "rejected"
      assert first["code"] == "payment_exceeds_outstanding"

      assert [retry] = submit!(conn, [payment_operation("g-rejected", 25_000, "op-over")])
      assert retry == first

      assert group_data(conn, "g-rejected")["deposit_paid_cents"] == 0
      assert group_data(conn, "g-rejected")["revision"] == 1
    end

    test "a retry still receives the original rejection even once it would be valid" do
      conn = build_conn()
      open_group!(conn, "g-now-valid")

      # Stale while the group is at revision 1.
      assert [stale] =
               submit!(conn, [
                 payment_operation("g-now-valid", 100, "op-stale-once")
                 |> Map.put("expected_revision", 2)
               ])

      assert stale["code"] == "stale_revision"
      assert stale["expected_revision"] == 2
      assert stale["actual_revision"] == 1

      # A later operation moves the group to revision 2, where the
      # remembered operation would now apply.
      assert [pay] = submit!(conn, [payment_operation("g-now-valid", 100, "op-later")])
      assert pay["revision"] == 2

      assert [retry] =
               submit!(conn, [
                 payment_operation("g-now-valid", 100, "op-stale-once")
                 |> Map.put("expected_revision", 2)
               ])

      assert retry == stale
      assert retry["actual_revision"] == 1

      assert group_data(conn, "g-now-valid")["deposit_paid_cents"] == 100
      assert group_data(conn, "g-now-valid")["revision"] == 2
    end

    test "retrying a stale operation with a corrected expected_revision conflicts" do
      conn = build_conn()
      open_group!(conn, "g-corrected")

      assert [stale] =
               submit!(conn, [
                 payment_operation("g-corrected", 100, "op-correct-me")
                 |> Map.put("expected_revision", 7)
               ])

      assert stale["code"] == "stale_revision"

      assert [conflict] =
               submit!(conn, [
                 payment_operation("g-corrected", 100, "op-correct-me")
                 |> Map.put("expected_revision", 1)
               ])

      assert conflict["status"] == "rejected"
      assert conflict["code"] == "operation_id_conflict"
      assert group_data(conn, "g-corrected")["deposit_paid_cents"] == 0
    end

    test "a structurally invalid operation is remembered and replayed" do
      conn = build_conn()

      malformed = %{
        "operation_id" => "op-nonsense",
        "type" => "nonsense",
        "occurred_on" => @occurred_on
      }

      assert [first] = submit!(conn, [malformed])
      assert first["code"] == "invalid_operation"

      assert [retry] = submit!(conn, [malformed])
      assert retry == first

      assert operation_data(conn, "op-nonsense") == first
    end
  end

  describe "identifier conflicts" do
    test "different content is rejected and the original record survives" do
      conn = build_conn()
      open_group!(conn, "g-conflict")

      assert [original] = submit!(conn, [payment_operation("g-conflict", 5000, "op-keep")])
      assert original["status"] == "applied"

      assert [conflict] =
               submit!(conn, [payment_operation("g-conflict", 6000, "op-keep")])

      assert conflict == %{
               "operation_id" => "op-keep",
               "status" => "rejected",
               "code" => "operation_id_conflict"
             }

      # The original record was not replaced: an exact retry still
      # replays the original result.
      assert [replay] = submit!(conn, [payment_operation("g-conflict", 5000, "op-keep")])
      assert replay == original

      assert group_data(conn, "g-conflict")["deposit_paid_cents"] == 5000
      assert operation_data(conn, "op-keep") == original
    end

    test "an added or removed field makes the payload different" do
      conn = build_conn()
      open_group!(conn, "g-fields")

      assert [original] = submit!(conn, [payment_operation("g-fields", 500, "op-fields")])
      assert original["status"] == "applied"

      assert [added] =
               submit!(conn, [
                 payment_operation("g-fields", 500, "op-fields")
                 |> Map.put("note", "retry")
               ])

      assert added["code"] == "operation_id_conflict"

      assert [removed] =
               submit!(conn, [
                 payment_operation("g-fields", 500, "op-fields")
                 |> Map.delete("occurred_on")
               ])

      assert removed["code"] == "operation_id_conflict"
    end

    test "a conflict against a remembered rejection keeps the rejection" do
      conn = build_conn()
      open_group!(conn, "g-conflict-rej")

      assert [rejection] =
               submit!(conn, [payment_operation("g-conflict-rej", 25_000, "op-rej")])

      assert rejection["code"] == "payment_exceeds_outstanding"

      assert [conflict] =
               submit!(conn, [payment_operation("g-conflict-rej", 100, "op-rej")])

      assert conflict["code"] == "operation_id_conflict"

      assert [replay] =
               submit!(conn, [payment_operation("g-conflict-rej", 25_000, "op-rej")])

      assert replay == rejection
      assert operation_data(conn, "op-rej") == rejection
    end
  end

  describe "transactional semantics" do
    test "a handled rejection commits its idempotency record but no domain change" do
      conn = build_conn()
      open_group!(conn, "g-txn-reject")

      assert [rejection] =
               submit!(conn, [payment_operation("g-txn-reject", 25_000, "op-txn-reject")])

      assert rejection["code"] == "payment_exceeds_outstanding"

      record = PartnerOperations.fetch("op-txn-reject")
      assert record != nil
      assert Jason.decode!(record.result) == rejection

      assert group_data(conn, "g-txn-reject")["deposit_paid_cents"] == 0
      assert group_data(conn, "g-txn-reject")["revision"] == 1
    end

    test "other operations in the batch continue in order around a rejection" do
      conn = build_conn()
      open_group!(conn, "g-continue")

      assert [rejected, applied] =
               submit!(conn, [
                 payment_operation("g-continue", 25_000, "op-over-continue"),
                 payment_operation("g-continue", 1000, "op-fine-continue")
               ])

      assert rejected["code"] == "payment_exceeds_outstanding"
      assert applied["status"] == "applied"
      assert applied["revision"] == 2

      assert group_data(conn, "g-continue")["deposit_paid_cents"] == 1000
    end

    test "an unexpected exception aborts the request with 500 and is not remembered" do
      conn = build_conn()

      # A nightly rate beyond the database's integer range crashes the
      # insert with an unexpected fault.
      faulting =
        open_operation("g-crash", "op-crash")
        |> Map.put("rooms", [%{"room_id" => "room-a", "nightly_rate_cents" => 2 ** 70}])

      assert_raise Exqlite.Error, fn ->
        post(conn, "/api/v1/partner-batches", %{"operations" => [faulting]})
      end

      # The HTTP request still aborts with a 500 response.
      {status, _headers, _body} =
        receive do
          {_ref, {status, headers, body}} -> {status, headers, body}
        after
          0 -> flunk("expected the faulting batch to abort with a 500 response")
        end

      assert status == 500

      assert PartnerOperations.fetch("op-crash") == nil

      missing = get(build_conn(), "/api/v1/groups/g-crash")
      assert json_response(missing, 404) == %{"error" => %{"code" => "group_not_found"}}

      not_found = get(build_conn(), "/api/v1/operations/op-crash")
      assert json_response(not_found, 404) == %{"error" => %{"code" => "operation_not_found"}}
    end

    test "work committed before an unexpected fault stays and replays on retry" do
      conn = build_conn()

      good = open_operation("g-fault-batch", "op-good")

      faulting =
        open_operation("g-fault-crash", "op-fault")
        |> Map.put("rooms", [%{"room_id" => "room-a", "nightly_rate_cents" => 2 ** 70}])

      assert_raise Exqlite.Error, fn ->
        post(conn, "/api/v1/partner-batches", %{"operations" => [good, faulting]})
      end

      # The first operation committed before the fault.
      data = group_data(conn, "g-fault-batch")
      assert data["group_id"] == "g-fault-batch"
      assert PartnerOperations.fetch("op-good") != nil
      assert PartnerOperations.fetch("op-fault") == nil

      # Retrying the batch replays the committed operation's result and
      # reattempts the faulting one.
      assert_raise Exqlite.Error, fn ->
        post(build_conn(), "/api/v1/partner-batches", %{"operations" => [good, faulting]})
      end

      assert group_data(conn, "g-fault-batch")["revision"] == 1
      assert PartnerOperations.fetch("op-fault") == nil

      assert [replayed] = submit!(build_conn(), [good])
      assert replayed["status"] == "applied"
      assert replayed["revision"] == 1
    end
  end

  describe "the operations read endpoint" do
    test "returns the stored result of an applied operation" do
      conn = build_conn()
      [result] = submit!(conn, [open_operation("g-read", "op-read")])

      read = get(conn, "/api/v1/operations/op-read")
      assert read.status == 200
      assert json_response(read, 200) == %{"data" => result}
    end

    test "returns the stored result of a rejected operation" do
      conn = build_conn()

      [rejection] =
        submit!(conn, [payment_operation("g-missing-read", 100, "op-read-rejected")])

      assert rejection["code"] == "group_not_found"

      read = get(conn, "/api/v1/operations/op-read-rejected")
      assert read.status == 200
      assert json_response(read, 200) == %{"data" => rejection}
    end

    test "returns the stored stale-revision details verbatim" do
      conn = build_conn()
      open_group!(conn, "g-read-stale")

      [stale] =
        submit!(conn, [
          payment_operation("g-read-stale", 100, "op-read-stale")
          |> Map.put("expected_revision", 9)
        ])

      assert stale["code"] == "stale_revision"

      read = get(conn, "/api/v1/operations/op-read-stale")
      assert read.status == 200
      assert json_response(read, 200) == %{"data" => stale}
    end

    test "an unknown operation returns 404 operation_not_found" do
      conn = get(build_conn(), "/api/v1/operations/op-never-seen")

      assert json_response(conn, 404) == %{"error" => %{"code" => "operation_not_found"}}
    end
  end

  describe "the durable audit record" do
    test "retains type, complete submitted content, and commit order" do
      conn = build_conn()

      open = open_operation("g-audit", "op-audit-1")
      rejected = payment_operation("g-audit", 25_000, "op-audit-2")
      applied = payment_operation("g-audit", 1000, "op-audit-3")

      [r1, r2, r3] = submit!(conn, [open, rejected, applied])
      assert r1["status"] == "applied"
      assert r2["status"] == "rejected"
      assert r3["status"] == "applied"

      trail = PartnerOperations.audit_trail()

      assert Enum.map(trail, & &1.operation_id) == ["op-audit-1", "op-audit-2", "op-audit-3"]

      assert Enum.map(trail, & &1.type) == [
               "open_group",
               "record_cash_payment",
               "record_cash_payment"
             ]

      # The complete submitted content, key order normalized.
      assert Enum.map(trail, &Jason.decode!(&1.payload)) == [open, rejected, applied]

      # The stored results match the returned ones.
      assert Enum.map(trail, &Jason.decode!(&1.result)) == [r1, r2, r3]
    end

    test "retains the submitted type even when the operation is invalid" do
      conn = build_conn()

      malformed = %{
        "operation_id" => "op-audit-nonsense",
        "type" => "explode",
        "occurred_on" => @occurred_on,
        "extra" => [1, "two", nil]
      }

      assert [result] = submit!(conn, [malformed])
      assert result["code"] == "invalid_operation"

      [record] = PartnerOperations.audit_trail()
      assert record.operation_id == "op-audit-nonsense"
      assert record.type == "explode"
      assert Jason.decode!(record.payload) == malformed
    end

    test "operations without a usable operation_id are not remembered" do
      conn = build_conn()

      without_id = %{
        "type" => "record_cash_payment",
        "occurred_on" => @occurred_on,
        "group_id" => "g-any",
        "amount_cents" => 1
      }

      assert [result] = submit!(conn, [without_id])
      assert result["code"] == "invalid_operation"

      assert [result] = submit!(conn, ["not-an-operation"])
      assert result["code"] == "invalid_operation"

      assert PartnerOperations.audit_trail() == []
    end
  end

  describe "payload equivalence" do
    test "canonical JSON sorts object keys recursively and keeps everything else" do
      assert PartnerOperations.canonical_json(%{"b" => 1, "a" => 2}) ==
               ~s({"a":2,"b":1})

      assert PartnerOperations.canonical_json([%{"z" => %{"y" => 1, "x" => 2}}]) ==
               ~s([{"z":{"x":2,"y":1}}])

      assert PartnerOperations.canonical_json(["b", "a"]) == ~s(["b","a"])

      assert PartnerOperations.canonical_json(%{
               "s" => "text",
               "i" => 7,
               "f" => 1.5,
               "t" => true,
               "n" => nil
             }) == ~s({"f":1.5,"i":7,"n":null,"s":"text","t":true})
    end
  end
end
