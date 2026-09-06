defmodule GroupStayWeb.Router do
  use GroupStayWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/api/v1", GroupStayWeb do
    pipe_through :api

    post "/partner-batches", ApiController, :submit_batch
    get "/groups/:group_id", ApiController, :show_group
    get "/ledger", ApiController, :ledger
  end
end
