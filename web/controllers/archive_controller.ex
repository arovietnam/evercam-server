defmodule EvercamMedia.ArchiveController do
  use EvercamMedia.Web, :controller
  alias EvercamMedia.ArchiveView
  alias EvercamMedia.Util
  import EvercamMedia.Snapshot.Storage, only: [delete_archive: 2]
  require Logger

  @status %{pending: 0, processing: 1, completed: 2, failed: 3}

  def index(conn, %{"id" => exid} = params) do
    current_user = conn.assigns[:current_user]
    camera = Camera.get_full(exid)
    status = params["status"]

    with :ok <- ensure_camera_exists(camera, exid, conn),
         :ok <- ensure_can_list(current_user, camera, conn)
    do
      archives =
        Archive
        |> Archive.by_camera_id(camera.id)
        |> Archive.with_status_if_given(status)
        |> Archive.get_all_with_associations

      render(conn, ArchiveView, "index.json", %{archives: archives})
    end
  end

  def show(conn, %{"id" => exid, "archive_id" => archive_id} = params) do
    current_user = conn.assigns[:current_user]
    camera = Camera.get_full(exid)

    with :ok <- valid_params(conn, params),
         :ok <- ensure_camera_exists(camera, exid, conn),
         :ok <- ensure_can_list(current_user, camera, conn)
    do
      archive = Archive.by_exid(archive_id)

      case archive do
        nil ->
          render_error(conn, 404, "Archive '#{archive_id}' not found!")
        _ ->
          render(conn, ArchiveView, "show.json", %{archive: archive})
      end
    end
  end

  def play(conn, %{"id" => exid, "archive_id" => archive_id}) do
    current_user = conn.assigns[:current_user]
    camera = Camera.get_full(exid)

    with :ok <- ensure_can_list(current_user, camera, conn) do
      seaweed_url = Application.get_env(:evercam_media, :seaweedfs_url)
      conn
      |> redirect(external: "#{seaweed_url}/#{exid}/clips/#{archive_id}.mp4")
    end
  end

  def create(conn, %{"id" => exid} = params) do
    current_user = conn.assigns[:current_user]
    camera = Camera.get_full(exid)

    with :ok <- ensure_camera_exists(camera, exid, conn),
         :ok <- ensure_can_list(current_user, camera, conn)
    do
      create_clip(params, camera, conn, current_user)
    end
  end

  def update(conn, %{"id" => exid, "archive_id" => archive_id} = params) do
    current_user = conn.assigns[:current_user]
    camera = Camera.get_full(exid)

    with :ok <- valid_params(conn, params),
         :ok <- ensure_camera_exists(camera, exid, conn),
         :ok <- ensure_can_list(current_user, camera, conn)
    do
      update_clip(conn, camera, params, archive_id)
    end
  end

  def pending_archives(conn, _) do
    requester = conn.assigns[:current_user]

    if requester do
      archive =
        Archive
        |> Archive.with_status_if_given(@status.pending)
        |> Archive.get_one_with_associations

      conn
      |> render(ArchiveView, "show.json", %{archive: archive})
    else
      render_error(conn, 401, "Unauthorized.")
    end
  end

  def delete(conn, %{"id" => exid, "archive_id" => archive_id} = params) do
    current_user = conn.assigns[:current_user]
    camera = Camera.get_full(exid)

    with :ok <- valid_params(conn, params),
         :ok <- ensure_camera_exists(camera, exid, conn),
         :ok <- ensure_can_delete(current_user, camera, conn),
         :ok <- ensure_archive(conn, archive_id)
    do
      Archive.delete_by_exid(archive_id)
      spawn(fn -> delete_archive(camera.exid, archive_id) end)
      CameraActivity.log_activity(current_user, camera, "archive deleted", %{ip: user_request_ip(conn)})
      json(conn, %{})
    end
  end

  defp create_clip(params, camera, conn, current_user) do
    timezone = camera |> Camera.get_timezone
    from_date = clip_date(params["from_date"], timezone)
    to_date = clip_date(params["to_date"], timezone)
    clip_exid = generate_exid(params["title"])

    current_date_time =
      Calendar.DateTime.now_utc
      |> Calendar.DateTime.to_erl
    user_id =
      params["requested_by"]
      |> User.by_username
      |> Util.deep_get([:id], "")

    params =
      params
      |> Map.delete("id")
      |> Map.delete("api_id")
      |> Map.delete("api_key")
      |> Map.merge(%{
        "requested_by" => user_id,
        "camera_id" => camera.id,
        "title" => params["title"],
        "from_date" => from_date,
        "to_date" => to_date,
        "status" => @status.pending,
        "exid" => clip_exid
      })

    changeset = Archive.changeset(%Archive{}, params)

    cond do
      !changeset.valid? ->
        render_error(conn, 400, Util.parse_changeset(changeset))
      to_date < from_date ->
        render_error(conn, 400, "To date cannot be less than from date.")
      current_date_time <= from_date ->
        render_error(conn, 400, "From date cannot be greater than current time.")
      current_date_time <= to_date ->
        render_error(conn, 400, "To date cannot be greater than current time.")
      to_date == from_date ->
        render_error(conn, 400, "To date and from date cannot be same.")
      date_difference(from_date, to_date) > 3600 ->
        render_error(conn, 400, "Clip duration cannot be greater than 60 minutes.")
      true ->
        case Repo.insert(changeset) do
          {:ok, archive} ->
            CameraActivity.log_activity(current_user, camera, "archive created", %{ip: user_request_ip(conn)})
            start_archive_creation(Application.get_env(:evercam_media, :run_spawn), archive.exid)
            render(conn |> put_status(:created), ArchiveView, "show.json", %{archive: archive |> Repo.preload(:camera) |> Repo.preload(:user)})
          {:error, changeset} ->
            render_error(conn, 400, Util.parse_changeset(changeset))
        end
    end
  end

  defp update_clip(conn, _camera, params, archive_id) do
    case Archive.by_exid(archive_id) do
      nil ->
        render_error(conn, 404, "Archive '#{archive_id}' not found!")
      archive ->
        status = parse_status(params["status"], archive)
        title = parse_title(params["title"], archive)
        public = parse_public(params["public"], archive)

        params =
          params
          |> Map.delete("id")
          |> Map.delete("api_id")
          |> Map.delete("api_key")
          |> Map.merge(%{
            "status" => status,
            "title" => title,
            "public" => public
          })

        changeset = Archive.changeset(archive, params)

        case Repo.update(changeset) do
          {:ok, archive} ->
            updated_archive = archive |> Repo.preload(:camera) |> Repo.preload(:user)
            send_archive_email(updated_archive.status, updated_archive)

            render(conn, ArchiveView, "show.json", %{archive: updated_archive})
          {:error, changeset} ->
            render_error(conn, 400, Util.parse_changeset(changeset))
        end
    end
  end

  defp start_archive_creation(true, archive_id) do
    spawn fn ->
      case Process.whereis(:archive_creator) do
        nil ->
          {:ok, pid} = GenServer.start_link(EvercamMedia.ArchiveCreator.ArchiveCreator, {}, name: :archive_creator)
          GenServer.cast(pid, {:create_archive, archive_id})
        pid ->
          GenServer.cast(pid, {:create_archive, archive_id})
      end
    end
  end
  defp start_archive_creation(_mode, _archive_id), do: :noop

  defp ensure_camera_exists(nil, exid, conn) do
    render_error(conn, 404, "Camera '#{exid}' not found!")
  end
  defp ensure_camera_exists(_camera, _exid, _conn), do: :ok

  defp ensure_can_list(current_user, camera, conn) do
    if current_user && Permission.Camera.can_list?(current_user, camera) do
      :ok
    else
      render_error(conn, 401, "Unauthorized.")
    end
  end

  defp ensure_can_delete(current_user, camera, conn) do
    if current_user && Permission.Camera.can_delete?(current_user, camera) do
      :ok
    else
      render_error(conn, 401, "Unauthorized.")
    end
  end

  defp valid_params(conn, params) do
    if present?(params["id"]) && present?(params["archive_id"]) do
      :ok
    else
      render_error(conn, 400, "Parameters are invalid!")
    end
  end

  defp present?(param) when param in [nil, ""], do: false
  defp present?(_param), do: true

  defp ensure_archive(conn, archive_id) do
    case Archive.by_exid(archive_id) do
      nil -> render_error(conn, 404, "Archive '#{archive_id}' not found!")
      _ -> :ok
    end
  end

  defp clip_date(unix_timestamp, _timezone) when unix_timestamp in ["", nil], do: nil
  defp clip_date(unix_timestamp, "Etc/UTC") do
    unix_timestamp
    |> Calendar.DateTime.Parse.unix!
    |> Calendar.DateTime.to_erl
  end
  defp clip_date(unix_timestamp, timezone) do
    unix_timestamp
    |> Calendar.DateTime.Parse.unix!
    |> Calendar.DateTime.to_erl
    |> Calendar.DateTime.from_erl!(timezone)
    |> Calendar.DateTime.shift_zone!("Etc/UTC")
    |> Calendar.DateTime.to_erl
  end

  defp date_difference(from_date, to_date) do
    from = Calendar.DateTime.from_erl!(to_date, "Etc/UTC")
    to = Calendar.DateTime.from_erl!(from_date, "Etc/UTC")
    case Calendar.DateTime.diff(from, to) do
      {:ok, seconds, _, :after} -> seconds
      _ -> 1
    end
  end

  defp generate_exid(title) when title in ["", nil], do: nil
  defp generate_exid(title) do
    clip_exid =
      title
      |> String.replace(~r/\W/, "")
      |> String.downcase
      |> String.slice(0..5)

    random_string = Enum.concat(?a..?z, ?0..?9) |> Enum.take_random(4)
    "#{clip_exid}-#{random_string}"
  end

  defp parse_status(nil, archive), do: archive.status
  defp parse_status(status, _archive), do: status

  defp parse_title(nil, archive), do: archive.title
  defp parse_title(title, _archive), do: title

  defp parse_public(nil, archive), do: archive.public
  defp parse_public(public, _archive), do: public

  defp send_archive_email(2, archive), do: EvercamMedia.UserMailer.archive_completed(archive, archive.user.email)
  defp send_archive_email(3, archive), do: EvercamMedia.UserMailer.archive_failed(archive, archive.user.email)
  defp send_archive_email(_, _), do: Logger.info "Archive updated!"
end
