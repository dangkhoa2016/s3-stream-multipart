# frozen_string_literal: true

module SharedSmokeTests
  def self.included(base)
    base.class_eval do
      def upload_small_file(path, key, content_type = nil)
        opts = { content_type: content_type }.compact
        args = build_upload_args(key, path, opts)
        client.upload_file(**args)
      end

      def verify_upload(key, expected_content)
        tmp = Tempfile.new(["verify", ".bin"])
        tmp.close
        bucket_name ? verify_multi_download(key, tmp) : verify_single_download(key, tmp)
        assert_equal expected_content, File.binread(tmp.path)
      ensure
        tmp&.unlink
      end

      def perform_head(key)
        bucket_name ? client.head_object(bucket: bucket_name, key: key) : client.head_object(key)
      end

      def perform_delete(key)
        bucket_name ? client.delete_object(bucket: bucket_name, key: key) : client.delete_object(key)
      end

      def perform_stream_download(key, &block)
        bucket_name ? client.download_stream(bucket: bucket_name, key: key, &block) : client.download_stream(key: key, &block)
      end

      def perform_multipart_upload(file_path, progress_calls, key: "/shared/multi.bin")
        opts = {
          key: key, local_path: file_path,
          part_size: 5 * 1024 * 1024,
          content_type: "application/octet-stream",
          metadata: { "source" => "shared_test" }
        }
        if bucket_name
          opts[:bucket] = bucket_name
        end
        opts[:on_progress] = ->(done, total) { progress_calls << [done, total] }
        client.upload_file(**opts)
      end

      private

      def build_upload_args(key, path, extra = {})
        if bucket_name
          { bucket: bucket_name, key: key, local_path: path, **extra }
        else
          { key: key, local_path: path, **extra }
        end
      end

      def verify_multi_download(key, tmp)
        client.download_file(bucket: bucket_name, key: key, destination_path: tmp.path)
      end

      def verify_single_download(key, tmp)
        client.download_file(key: key, destination_path: tmp.path)
      end

      public

      def test_shared_small_file_upload
        src = Tempfile.new(["shared_small", ".bin"])
        src.binmode
        src.write("hello world from shared smoke test")
        src.flush
        upload_small_file(src.path, "/shared/small.txt", "text/plain")
        verify_upload("/shared/small.txt", "hello world from shared smoke test")
      ensure
        src&.unlink
      end

      def test_shared_multipart_upload_with_progress
        src_path, _src_md5 = create_temp_binary_file(6 * 1024 * 1024)
        progress_calls = []
        result = perform_multipart_upload(src_path, progress_calls)
        assert result, "upload should return a result"
        assert progress_calls.any?, "progress should have been called"
      ensure
        File.delete(src_path) if src_path && File.exist?(src_path)
      end

      def test_shared_head_and_delete
        src = Tempfile.new(["shared_head", ".txt"])
        src.write("head and delete test")
        src.close
        upload_small_file(src.path, "/shared/head_del.txt")
        info = perform_head("/shared/head_del.txt")
        assert info[:content_length]
        assert info[:etag]
        perform_delete("/shared/head_del.txt")
      ensure
        src&.unlink
      end

      def test_shared_stream_download
        content = "stream download content for shared test"
        src = Tempfile.new(["shared_stream", ".txt"])
        src.write(content)
        src.close
        upload_small_file(src.path, "/shared/stream.txt")
        chunks = []
        perform_stream_download("/shared/stream.txt") { |chunk| chunks << chunk }
        assert_equal content, chunks.join
      ensure
        src&.unlink
      end
    end
  end
end

module SharedStateTests
  def self.included(base)
    base.class_eval do
      def setup_shared_state
        @state_tmp = Dir.mktmpdir("shared_state")
        @state_path = File.join(@state_tmp, "state.json")
      end

      def cleanup_shared_state
        FileUtils.rm_rf(@state_tmp) if @state_tmp
      end

      def shared_state(parts: { 1 => "e1", 2 => "e2" })
        UploadState.new(
          key: "/shared/state.bin", local_path: "/tmp/fake",
          part_size: 5_242_880, total_size: 10_485_760,
          parts: parts, upload_id: "shared_uid"
        )
      end

      def test_shared_state_save_load
        setup_shared_state
        state = shared_state
        state.save_to_file(@state_path)
        assert File.exist?(@state_path)
        loaded = UploadState.from_file(@state_path)
        assert_equal state.key, loaded.key
        assert_equal state.upload_id, loaded.upload_id
        assert_equal state.completed_parts_count, loaded.completed_parts_count
      ensure
        cleanup_shared_state
      end

      def test_shared_state_bytes_progress
        state = shared_state
        assert_equal 2 * 5_242_880, state.bytes_uploaded
        assert_equal 50.0, state.progress_percentage
        assert_equal 3, state.next_part_number
      end

      def test_shared_state_to_h_roundtrip
        state = shared_state
        hash = state.to_h
        restored = UploadState.new(hash)
        assert_equal state.upload_id, restored.upload_id
        assert_equal state.part_size, restored.part_size
      end

      def test_shared_state_json_roundtrip
        state = shared_state
        json = state.to_json
        restored = UploadState.from_json(json)
        assert_equal state.upload_id, restored.upload_id
        assert_equal 2, restored.completed_parts_count
      end
    end
  end
end

module SharedConcurrentTests
  def self.included(base)
    base.class_eval do
      def build_tracking_host
        host = Object.new
        host.instance_variable_set(:@tracking_mtx, Mutex.new)
        host.instance_variable_set(:@in_progress_parts, {})
        host.instance_variable_set(:@thread_states, {})
        client = Object.new
        def client.log_debug(msg); end
        host.instance_variable_set(:@client, client)
        host.extend(S3ThreadTracking)
        host
      end

      def test_shared_thread_tracking_register
        host = build_tracking_host
        host.register_thread("t1", 0)
        states = host.instance_variable_get(:@thread_states)
        assert_equal "started", states["t1"][:status]
        host.finish_thread("t1", 5)
        assert_equal "finished", states["t1"][:status]
      end

      def test_shared_in_progress_parts
        host = build_tracking_host
        host.register_thread("t2", 0)
        host.mark_part_in_progress(3, "t2")
        parts = host.instance_variable_get(:@in_progress_parts)
        assert_equal "t2", parts[3]
        host.mark_part_error(3, "t2")
        refute parts.key?(3)
      end
    end
  end
end
