/*
This file is part of GameHub.
Copyright (C) 2018-2019 Anatoliy Kashkin

GameHub is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

GameHub is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with GameHub.  If not, see <https://www.gnu.org/licenses/>.
*/

using GLib;
using Gee;
using Soup;

using GameHub.Utils.Downloader;

namespace GameHub.Utils.Downloader.SoupDownloader
{
	public class SoupDownloader: Downloader
	{
		private Session session;

		private HashTable<string, SoupDownload> downloads;
		private HashTable<string, DownloadInfo> dl_info;
		private ArrayQueue<string> dl_queue;

		private static string[] URL_SCHEMES = { "http", "https" };
		private static string[] FILENAME_BLACKLIST = { "download" };

		public SoupDownloader()
		{
			downloads = new HashTable<string, SoupDownload>(str_hash, str_equal);
			dl_info = new HashTable<string, DownloadInfo>(str_hash, str_equal);
			dl_queue = new ArrayQueue<string>();
			session = new Session.with_options(
				"max-conns", 32,
				"max-conns-per-host", 16,
				null
			);
		}

		public override Download? get_download(string id)
		{
			lock(downloads)
			{
				return downloads.get(id);
			}
		}

		public SoupDownload? get_file_download(File? remote)
		{
			if(remote == null) return null;
			lock(downloads)
			{
				return (SoupDownload?) downloads.get(remote.get_uri());
			}
		}

		public async File? download(File remote, File local, DownloadInfo? info=null, bool preserve_filename=true, bool queue=true) throws Error
		{
			if(remote == null || remote.get_uri() == null || remote.get_uri().length == 0) return null;

			var uri = remote.get_uri();
			var download = get_file_download(remote);

			if(download != null) return yield await_download(download);

			if(local.query_exists())
			{
				if(GameHub.Application.log_downloader)
				{
					debug("[SoupDownloader] '%s' is already downloaded", uri);
				}
				return local;
			}

			var tmp = File.new_for_path(local.get_path() + "~");

			download = new SoupDownload(remote, local, tmp);
			download.session = session;

			lock(downloads)
			{
				downloads.set(uri, download);
			}

			download_started(download);

			if(info != null)
			{
				info.download = download;

				lock(dl_info)
				{
					dl_info.set(uri, info);
				}

				dl_started(info);
			}

			if(GameHub.Application.log_downloader)
			{
				debug("[SoupDownloader] Downloading '%s'...", uri);
			}

			download.status = new FileDownload.Status(Download.State.STARTING);

			try
			{
				if(remote.get_uri_scheme() in URL_SCHEMES)
					yield download_from_http(download, preserve_filename, queue);
				else
					yield download_from_filesystem(download);
			}
			catch(IOError.CANCELLED error)
			{
				download.status = new FileDownload.Status(Download.State.CANCELLED);
				download_cancelled(download, error);
				if(info != null) dl_ended(info);
				throw error;
			}
			catch(Error error)
			{
				download.status = new FileDownload.Status(Download.State.FAILED);
				download_failed(download, error);
				if(info != null) dl_ended(info);
				throw error;
			}
			finally
			{
				lock(downloads) downloads.remove(uri);
				lock(dl_info)   dl_info.remove(uri);
				lock(dl_queue)  dl_queue.remove(uri);
			}

			if(download.local_tmp.query_exists())
			{
				download.local_tmp.move(download.local, FileCopyFlags.OVERWRITE);
			}

			if(GameHub.Application.log_downloader)
			{
				debug("[SoupDownloader] Downloaded '%s'", uri);
			}

			download_finished(download);
			if(info != null) dl_ended(info);

			return download.local;
		}

		private async void download_from_http(SoupDownload download, bool preserve_filename=true, bool queue=true) throws Error
		{
			var msg = new Message("GET", download.remote.get_uri());
			download.message = msg;
			download.cancellable = new Cancellable();

			if(queue)
			{
				yield await_queue(download);
				download.status = new FileDownload.Status(Download.State.STARTING);
			}

			if(download.is_cancelled)
			{
				throw new IOError.CANCELLED("Download cancelled by user");
			}

			GLib.Error? err = null;

			FileOutputStream? local_stream = null;

			int64 dl_bytes = 0;
			int64 dl_bytes_total = 0;

			int64 resume_from = 0;
			var resume_dl = false;

			if(download.local_tmp.get_basename().has_suffix("~") && download.local_tmp.query_exists())
			{
				var info = yield download.local_tmp.query_info_async(FileAttribute.STANDARD_SIZE, FileQueryInfoFlags.NONE);
				resume_from = info.get_size();
				if(resume_from > 0)
				{
					resume_dl = true;
					msg.request_headers.set_range(resume_from, -1);
					if(GameHub.Application.log_downloader)
					{
						debug(@"[SoupDownloader] Download part found, size: $(resume_from)");
					}
				}
			}

			msg.got_headers.connect(() => {
				dl_bytes_total = msg.response_headers.get_content_length();
				download.set_total_bytes(dl_bytes_total);
				if(GameHub.Application.log_downloader)
				{
					debug(@"[SoupDownloader] Content-Length: $(dl_bytes_total)");
				}
				try
				{
					if(preserve_filename)
					{
						string filename = null;
						string disposition = null;
						HashTable<string, string> dparams = null;

						if(msg.response_headers.get_content_disposition(out disposition, out dparams))
						{
							if(disposition == "attachment" && dparams != null)
							{
								filename = dparams.get("filename");
								if(filename != null && GameHub.Application.log_downloader)
								{
									debug(@"[SoupDownloader] Content-Disposition: filename=%s", filename);
								}
							}
						}

						if(filename == null)
						{
							filename = download.remote.get_basename();
						}

						if(filename != null && !(filename in FILENAME_BLACKLIST))
						{
							download.local = download.local.get_parent().get_child(filename);
						}
					}

					if(download.local.query_exists())
					{
						if(GameHub.Application.log_downloader)
						{
							debug(@"[SoupDownloader] '%s' exists", download.local.get_path());
						}
						var info = download.local.query_info(FileAttribute.STANDARD_SIZE, FileQueryInfoFlags.NONE);
						if(info.get_size() == dl_bytes_total)
						{
							download.cancellable.cancel();
							return;
						}
					}
					if(GameHub.Application.log_downloader)
					{
						debug(@"[SoupDownloader] Downloading to '%s'", download.local.get_path());
					}

					int64 rstart = -1, rend = -1;
					if(resume_dl && msg.response_headers.get_content_range(out rstart, out rend, out dl_bytes_total))
					{
						if(GameHub.Application.log_downloader)
						{
							debug(@"[SoupDownloader] Content-Range is supported($(rstart)-$(rend)), resuming from $(resume_from)");
							debug(@"[SoupDownloader] Content-Length: $(dl_bytes_total)");
						}
						dl_bytes = resume_from;
						local_stream = download.local_tmp.append_to(FileCreateFlags.NONE);
					}
					else
					{
						local_stream = download.local_tmp.replace(null, false, FileCreateFlags.REPLACE_DESTINATION);
					}
				}
				catch(Error e)
				{
					warning(e.message);
				}
			});

			try
			{
				InputStream response_stream = yield session.send_async(msg, Priority.DEFAULT, download.cancellable);

				if (download.is_cancelled)
					throw new IOError.CANCELLED("Download cancelled by user");

				uint8[] buffer = new uint8[8192];
				ssize_t bytes_read;
				int64 last_update = get_real_time();
				int64 dl_bytes_from_last_update = 0;

				while ((bytes_read = yield response_stream.read_async(buffer, Priority.DEFAULT, download.cancellable)) > 0)
				{
					if (download.is_cancelled)
						throw new IOError.CANCELLED("Download cancelled by user");

					if (local_stream == null)
						throw new IOError.CANCELLED("Stream closed unexpectedly");

					size_t bytes_written;
					yield local_stream.write_all_async(buffer[0:bytes_read], Priority.DEFAULT, download.cancellable, out bytes_written);
					dl_bytes += bytes_read;
					dl_bytes_from_last_update += bytes_read;

					int64 now = get_real_time();
					int64 diff = now - last_update;
					if(diff > 1000000)
					{
						int64 dl_speed = (int64) (((double) dl_bytes_from_last_update) / ((double) diff) * ((double) 1000000));
						download.status = new FileDownload.Status(Download.State.DOWNLOADING, dl_bytes, dl_bytes_total, dl_speed);
						last_update = now;
						dl_bytes_from_last_update = 0;
					}
				}
			}
			catch(Error e)
			{
				err = e;
			}

			if(local_stream != null)
				yield local_stream.close_async(Priority.DEFAULT);

			if(msg.get_status() != Status.OK && msg.get_status() != Status.PARTIAL_CONTENT)
			{
				if(download.cancellable.is_cancelled() || (err is IOError.CANCELLED))
					throw new IOError.CANCELLED("Download cancelled by user");

				if(err == null)
					err = new GLib.Error(IOError.quark(), (int) msg.get_status(), msg.get_reason_phrase());

				throw err;
			}
		}

		private async File? await_download(SoupDownload download) throws Error
		{
			File downloaded_file = null;
			Error download_error = null;

			SourceFunc callback = await_download.callback;
			var download_finished_id = download_finished.connect((downloader, downloaded) => {
				if(((SoupDownload) downloaded).remote.get_uri() != download.remote.get_uri()) return;
				downloaded_file = ((SoupDownload) downloaded).local_tmp;
				callback();
			});
			var download_cancelled_id = download_cancelled.connect((downloader, cancelled_download, error) => {
				if(((SoupDownload) cancelled_download).remote.get_uri() != download.remote.get_uri()) return;
				download_error = error;
				callback();
			});
			var download_failed_id = download_failed.connect((downloader, failed_download, error) => {
				if(((SoupDownload) failed_download).remote.get_uri() != download.remote.get_uri()) return;
				download_error = error;
				callback();
			});

			yield;

			disconnect(download_finished_id);
			disconnect(download_cancelled_id);
			disconnect(download_failed_id);

			if(download_error != null) throw download_error;

			return downloaded_file;
		}

		private async void await_queue(SoupDownload download)
		{
			lock(dl_queue)
			{
				if(download.remote.get_uri() in dl_queue) return;
				dl_queue.add(download.remote.get_uri());
			}

			var download_finished_id = download_finished.connect((downloader, downloaded) => {
				lock(dl_queue) dl_queue.remove(((SoupDownload) downloaded).remote.get_uri());
			});
			var download_cancelled_id = download_cancelled.connect((downloader, cancelled_download, error) => {
				lock(dl_queue) dl_queue.remove(((SoupDownload) cancelled_download).remote.get_uri());
			});
			var download_failed_id = download_failed.connect((downloader, failed_download, error) => {
				lock(dl_queue) dl_queue.remove(((SoupDownload) failed_download).remote.get_uri());
			});

			while(dl_queue.peek() != null && dl_queue.peek() != download.remote.get_uri() && !download.is_cancelled)
			{
				download.status = new FileDownload.Status(Download.State.QUEUED);
				yield Utils.sleep_async(2000);
			}

			disconnect(download_finished_id);
			disconnect(download_cancelled_id);
			disconnect(download_failed_id);
		}

		private async void download_from_filesystem(SoupDownload download) throws GLib.Error
		{
			if(download.remote == null || !download.remote.query_exists()) return;
			try
			{
				if(GameHub.Application.log_downloader)
				{
					debug("[SoupDownloader] Copying '%s' to '%s'", download.remote.get_path(), download.local_tmp.get_path());
				}
				yield download.remote.copy_async(
					download.local_tmp,
					FileCopyFlags.OVERWRITE,
					Priority.DEFAULT,
					null,
					(current, total) => { download.status = new FileDownload.Status(Download.State.DOWNLOADING, current, total); });
			}
			catch(IOError.EXISTS error){}
		}
	}

	public class SoupDownload: FileDownload, PausableDownload
	{
		public weak Session? session;
		public Message? message;
		public Cancellable? cancellable;
		public bool is_cancelled = false;
		private int64 paused_position = -1;
		private int64 total_bytes = -1;   // store total download size

		public SoupDownload(File remote, File local, File local_tmp)
		{
			base(remote, local, local_tmp);
		}

		public void set_total_bytes(int64 total)
		{
			total_bytes = total;
		}

		public void pause()
		{
			if (cancellable != null && !cancellable.is_cancelled()) {
				cancellable.cancel();
				message = null;
			}

			try {
				var file_info = local_tmp.query_info(FileAttribute.STANDARD_SIZE, FileQueryInfoFlags.NONE);
				paused_position = file_info.get_size();
				_status = new FileDownload.Status(Download.State.PAUSED, paused_position, total_bytes);
				status_change(_status);
				if (GameHub.Application.log_downloader)
					debug(@"[SoupDownloader] Paused at $(paused_position) bytes");
			} catch (Error e) {
				warning("[SoupDownloader] Failed to get file size on pause: %s", e.message);
				paused_position = -1;
			}
		}

		public void resume()
		{
			if (paused_position > 0) {
				if (GameHub.Application.log_downloader)
					debug(@"[SoupDownloader] Resuming from $(paused_position) bytes");
				_status = new FileDownload.Status(Download.State.STARTING, paused_position, total_bytes);
				status_change(_status);
				DownloadManager.get_instance().soup_downloader.download.begin(remote, local, null, true, true);
				paused_position = -1;
			} else {
				warning("[SoupDownloader] Cannot resume: no valid paused position.");
			}
		}

		public override void cancel()
		{
			is_cancelled = true;
			if(cancellable != null && !cancellable.is_cancelled())
			{
				cancellable.cancel();
			}
		}
	}
}
