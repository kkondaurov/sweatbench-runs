defmodule GroupStayWeb.Router do
  use GroupStayWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/api/v1", GroupStayWeb do
    pipe_through :api

    post "/partner-batches", BatchController, :create
    get "/operations/:operation_id", OperationController, :show
    get "/payments/:payment_operation_id", PaymentController, :show
    get "/groups/:group_id", GroupController, :show
    get "/guests/:guest_id/credit", GuestCreditController, :show
    get "/finance/daily-report", FinanceReportController, :show
    get "/ledger", LedgerController, :show
  end
end
