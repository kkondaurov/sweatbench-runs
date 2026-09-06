defmodule GroupStayWeb.Router do
  use GroupStayWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/api", GroupStayWeb do
    pipe_through :api

    scope "/v1" do
      post "/partner-batches", PartnerBatchesController, :create
      get "/groups/:group_id", GroupsController, :show
      get "/guests/:guest_id/credit", GuestsController, :credit
      get "/ledger", LedgerController, :show
    end
  end
end
