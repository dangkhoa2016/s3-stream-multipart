# Báo Cáo Phân Tích Coverage — S3 Upload

> **Tổng quan:** Sau khi chạy `rake test` (đã sửa để chạy 1 process duy nhất), coverage ước tính ~68%.
> Báo cáo này chỉ ra những **khoảng trống** cần test để đạt 100% line coverage.

---

## 1. `src/core/base_client.rb` (619 lines)

### Chưa có test
| Phương thức | Dòng | Lý do thiếu |
|---|---|---|
| `sse_headers` | 118–137 | Chưa có test nào dùng `sse` parameter khi khởi tạo client. Cả 3 nhánh AES256, aws:kms, customer đều chưa test |
| `backoff_with_jitter` | 140–143 | Chưa có unit test riêng cho backoff calculation |
| `extract_metadata_from_headers` | 146–155 | Chưa có direct test (tested indirectly qua HEAD) |
| `etag_matches_file?` | 222–230 | Chưa có test cho multipart ETag (contains "-") và MD5 match |
| `load_download_state` | 234–251 | Chưa có test nào dùng parallel download with state file |
| `setup_logger` — `log_color: true` branch | 283–303 | Chưa có test nào dùng `log_color: true` |
| `log_request_details` | 315–319 | Phụ thuộc `@debug_mode` — chưa có test nào enable debug trên S3Client |
| `log_response_details` | 322–331 | Tương tự, cần `@debug_mode: true` |
| `extract_total_size` | 589–596 | Chưa có direct test |
| `adjust_part_size` | 600–618 | Đã test trên S3MultiBucketClient, **thiếu trên S3Client** |
| `build_http_request` | 400–465 | Chưa có direct unit test — đặc biệt nhánh `stream: true`, `content_length`, IO body |
| `apply_signer_headers!` | 471–500 | Chưa có direct test |
| `http_start` (base version) | 504–511 | Chưa có test riêng |

---

## 2. `src/core/event_registry.rb` (83 lines)

### Chưa có test
| Phương thức | Dòng | Lý do thiếu |
|---|---|---|
| `clear_callbacks!` | 59–61 | Chưa có test gọi `clear_callbacks!` và verify |
| `drain_logs` edge cases | 67–82 | Chưa test drain với queue rỗng, hoặc drain multiple lần (tested trên multi-bucket nhưng thiếu trên S3Client) |

---

## 3. `src/core/request_executor.rb` (62 lines)

### Chưa có test
| Phương thức | Dòng | Lý do thiếu |
|---|---|---|
| `execute_with_retry` | 22–61 | Toàn bộ retry logic chỉ được test gián tiếp. Cần mock/test các nhánh: transient error retry, S3 5xx retry, 429 retry, exhausted retries -> raise |

---

## 4. `src/core/upload_state_manager.rb` (139 lines)

### Chưa có test
| Phương thức | Dòng | Lý do thiếu |
|---|---|---|
| `save_state` — `rename_mutex` branch | 64–73 | Chưa có test verify atomic write với mutex |
| `save_state` — stale snapshot skip | 66–68 | Chưa có test cho nhánh stale snapshot |
| `save_state` — `@_last_saved_parts_count` | 66–72 | Chưa test lifecycle của biến này |
| `validate_state` — MD5 mismatch | 115–126 | Chưa có test cho case file MD5 thay đổi |
| `cleanup_state` — error path | 136–138 | Chưa test khi File.delete raises |

---

## 5. `src/s3_client.rb` (1067 lines)

### Chưa có test
| Phương thức | Dòng | Lý do thiếu |
|---|---|---|
| `initialize` — `sse`, `compute_md5`, `log_color` params | 207–209 | Chưa có test với các param này |
| `upload_file` — `skip_existing: true` path | 277–283 | Chưa có test cho skip_existing |
| `upload_file` — `cache_control` | 300–301, 313–314 | Chưa có test với cache_control |
| `upload_file` — error path: file not found | 271 | `Errno::ENOENT` — chưa test |
| `upload_file` — error path: part_size < 5MB | 274 | `ArgumentError` — chưa test |
| `upload_file` — error path: exceeds 10k parts | 275 | `ArgumentError` — chưa test |
| `upload_file_multipart` — `resume_state` param | 400–404 | Chưa test resume từ UploadState object |
| `upload_file_multipart` — `raise_on_error: true` | 424 | Chưa test error propagation |
| `upload_file_multipart` — `cache_control` | 377 | Chưa test |
| `resume_upload` — state file not found | 438 | `Errno::ENOENT` — chưa test |
| `resume_upload` — file size changed | 445–446 | `ArgumentError` — chưa test |
| `resume_upload` — invalid state | 441 | `ArgumentError` — chưa test |
| `download_file` — có Range header | 497 | Tested, nhưng thiếu error case (server trả về non-200) |
| `download_stream` — error path | 523 | Thiếu test block_given? false |
| `perform_request` — `stream: true` và `content_length` paths | 850–887 | Chưa có direct test |
| `resolve_style` | 790–801 | Chưa có test riêng — đặc biệt `:auto` với/không endpoint |
| `build_endpoint` | 803–811 | Chưa có test riêng — các nhánh endpoint, path style vs virtual_hosted |
| `safe_abort` — error path | 981–984 | Chưa test khi abort fails |
| `execute_multipart_upload` — tất cả error paths | 1048–1059 | Chưa test when upload fails with/without state_file |
| `upload_parts_parallel` — thread lifecycle | 88–229 | Chưa test Interrupt handling, thread errors |
| `deep_dup_thread_states` | 231–235 | Chưa có direct test |
| `upload_part_via` — retry paths | 237–273 | Chưa mock failure để test retry |

---

## 6. `src/s3_multi_bucket_client.rb` (1147 lines)

### Chưa có test
| Phương thức | Dòng | Lý do thiếu |
|---|---|---|
| `initialize` — `compute_md5`, `sse` params | 205 | Chưa test |
| `upload_file` — `skip_existing: true` | 252–258 | Chưa test skip_existing path |
| `upload_file_multipart` — `raise_on_error: true` | 372 | Chưa test error propagation |
| `upload_file_multipart` — `cache_control` | 337–341 | Chưa test |
| `upload_file_multipart` — `resume_state` via state_file auto-load mismatch | 1077–1084 | Chưa test state mismatch/warning path |
| `resume_upload` — error paths | 606–668 | `Errno::ENOENT`, invalid state, file size mismatch |
| `download_file` — retry logic | 427–471 | Chưa mock transient errors để test retry |
| `download_file` — Range request | 397–406 | Chưa test Range với Array format |
| `download_file_resume` — retry logic | 741–781 | Chưa test retry path |
| `download_stream` — retry logic | 813–850 | Chưa test retry path |
| `download_file_parallel` | 867–893 | Chưa có test nào cho parallel download trên multi-bucket client |
| `signed_request` — body_stream path | 979–982 | Chưa có test streaming PUT với body_stream |
| `signed_request_via` | 587–603 | Chưa có test |
| `initiate_multipart_upload` — error path (parse UploadId fails) | 1035–1038 | Chưa test |
| `prepare_multipart_state` — auto-load state file | 1064–1090 | Tested indirectly, nhưng thiếu edge case: invalid JSON, corrupt state |
| `finalize_upload` | 1120–1142 | Tested indirectly |
| `complete_multipart_upload(state)` — error path | 1051–1052 | Chưa test |
| `extract_total_size` | 589–596 | Chưa có direct test |

---

## 7. `src/states/upload_state.rb` (193 lines)

### Chưa có test
| Phương thức | Dòng | Lý do thiếu |
|---|---|---|
| `total_file_size` | 161–164 | Chưa có test |
| `from_file` — file not found | 90 | `Errno::ENOENT` — chưa test |
| `normalize_parts` — empty/unknown input | 182–183 | Chưa test case unexpected type |
| `in_progress_part_numbers` | 140–142 | Chưa có direct test |

---

## 8. `src/states/download_state.rb` (127 lines)

### Hầu như chưa có test nào!
| Phương thức | Dòng | Lý do thiếu |
|---|---|---|
| `initialize` | 16–31 | Chưa có unit test |
| `to_h` / `to_json` | 33–48 | Chưa có test |
| `from_json` | 50–62 | Chưa có test — đặc biệt array-format parts (backward compat) |
| `from_file` | 64–67 | Chưa có test |
| `save_to_file` | 69–74 | Chưa có test |
| `total_parts` | 76–79 | Chưa có test |
| `completed_parts_count` | 81–83 | Chưa có test |
| `bytes_downloaded` | 85–87 | Chưa có test |
| `progress_percentage` | 89–92 | Chưa có test |
| `pending_part_numbers` | 98–102 | Chưa có test |
| `summary` | 104–107 | Chưa có test |
| `normalize_parts` — Array format | 117–122 | Chưa có test backward compat |

---

## 9. `src/concurrent/parallel_uploader.rb` (349 lines)

### Chưa có direct test
| Phương thức | Dòng | Lý do thiếu |
|---|---|---|
| `upload_all!` | 53–91 | Only tested indirectly via PartUploader |
| `create_thread_pool` | 204–287 | Testing indirectly is complex; cần mock S3 |
| `calculate_pre_uploaded_bytes` | 165–170 | Chưa có direct unit test |
| `join_threads` — Interrupt handling | 336–343 | Chưa test Interrupt |
| `raise_upload_errors` | 345–348 | Chưa test |

---

## 10. `src/concurrent/parallel_downloader.rb` (282 lines)

### Chưa có direct test
| Phương thức | Dòng | Lý do thiếu |
|---|---|---|
| `download_all!` | 42–71 | Only tested indirectly |
| `create_thread_pool` | 165–233 | Testing indirectly |
| `execute_range_download` | 107–126 | Tested indirectly, thiếu size mismatch error path |
| `calculate_part_geometry` | 235–240 | Chưa có direct unit test |
| `progress_callback_parts` | 242–248 | Chưa có direct test |
| `current_downloaded_bytes` | 265–267 | Chưa có direct test |
| `raise_download_errors` | 278–281 | Chưa test |

---

## 11. `src/concurrent/parallel_upload_runner.rb` (274 lines)

### Chưa có direct test
Toàn bộ module chỉ được test gián tiếp qua `upload_file` integration tests.
Cần test riêng: `deep_dup_thread_states`, `upload_part_via` retry paths,
`upload_parts_parallel` với state_file và không state_file.

---

## 12. `src/concurrent/parallel_download_runner.rb` (101 lines)

### Chưa có direct test
| Phương thức | Dòng | Lý do thiếu |
|---|---|---|
| `run_parallel_download` | 32–101 | Chưa có test nào gọi `download_file_parallel` với state_file trên S3Client |
| Error path | 95–99 | Chưa test rescue branch |

---

## 13. `src/concurrent/thread_tracking.rb` (54 lines)

### Chưa có direct test
| Phương thức | Dòng | Lý do thiếu |
|---|---|---|
| `register_thread` | 15–24 | Chưa có direct unit test |
| `mark_part_in_progress` | 26–32 | Chưa có direct test |
| `mark_part_error` | 34–39 | Chưa có direct test |
| `finish_thread` | 41–47 | Chưa có direct test |
| `deep_dup_thread_states` | 49–53 | Chưa có direct test |

---

## 14. `src/extras/bulk_uploader.rb` (253 lines)

### Chưa có test
| Phương thức | Dòng | Lý do thiếu |
|---|---|---|
| `deduplicate_keys` — actual duplicate scenario | 104–120 | Chưa có test với duplicate keys |
| `check_skip_existing` | 199–213 | Chưa có test với `skip_existing: true` |
| `state_file_for` | 225–229 | Chưa có test |
| `upload_one` — with state_dir | 172–180 | Chưa test resume với state file |
| `normalize_prefix` — nil/empty | 220–223 | Chưa test với nil prefix |
| `detect_content_type` — unknown extension | 215–218 | Chưa test |

---

## 15. `src/extras/helper.rb` (156 lines)

### Chưa có test
| Phương thức | Dòng | Lý do thiếu |
|---|---|---|
| `S3Helper.upload` — `part_size` auto-calculation | 31–34 | Chưa test khi file > threshold và không có part_size |
| `S3Helper.download` — `parallel: true` | 89–101 | Chưa test parallel download path |
| `S3Helper.download` — `range:` option | 109–115 | Chưa test range parameter forwarding |
| `S3Helper.upload_bulk` | 139–155 | Tested indirectly via bulk tests |

---

## 16. `src/extras/retry_helper.rb` (55 lines)

### Chưa có test
| Phương thức | Dòng | Lý do thiếu |
|---|---|---|
| `S3RetryHelper.retry_with_backoff` — class method | 20–46 | Chưa có direct unit test với mock |
| `S3RetryHelper#retry_with_backoff` — instance method | 49–54 | Chưa có direct unit test |

---

## Tổng Kết — Ưu Tiên Cao

### Must-have để coverage 70% → 85%
1. **DownloadState** (`states/download_state.rb`) — toàn bộ file chưa test
2. **SSE headers** (`base_client.rb#sse_headers`) — 3 nhánh chưa test
3. **adjust_part_size** trên S3Client — đã test trên multi-bucket nhưng thiếu trên single
4. **skip_existing** path — cả 2 clients
5. **upload_file_part_size/part_count validations** — `Errno::ENOENT`, `ArgumentError` exceptions
6. **load_download_state** + **run_parallel_download** — parallel download state management

### Must-have để 85% → 95%
7. **Retry logic** — `execute_with_retry`, `retry_with_backoff`, `upload_part_via` retry paths
8. **upload_file_multipart resume_state parameter** — cả 2 clients
9. **Error paths** trong `execute_multipart_upload`, `resume_upload`, `upload_file_multipart`
10. **raise_on_error: true branch**
11. **build_http_request** — stream: true, content_length, IO body
12. **resolve_style + build_endpoint** — unit test các combinations
13. **etag_matches_file?** — multipart ETag branch

### Must-have để 95% → 100%
14. **parallel_uploader, parallel_downloader** — template method edge cases
15. **thread_tracking** — direct unit tests
16. **upload_state_manager#save_state** — stale snapshot skip, rename_mutex
17. **upload_state_manager#validate_state** — MD5 mismatch
18. **bulk_uploader** — deduplicate_keys, check_skip_existing, state_file_for
19. **S3Helper.download parallel: true path**
20. **load_download_state** — error paths (file not found, corrupt)
21. **setup_logger** — log_color: true branch
22. **clear_callbacks!**
