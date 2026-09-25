# deploy-state

Nhánh này KHÔNG chứa mã nguồn. Nó lưu release manifest — bản ghi "môi trường nào đang chạy
image nào" — do CD ghi sau mỗi lần deploy + smoke test PASS (xem docs/adr/ADR-005).

    dev.json  staging.json  prod.json     bản đã deploy thành công gần nhất của từng môi trường
    releases/<tag>.json                   snapshot đóng băng của một release (rc-vX / vX)

Đừng sửa tay. Lịch sử deploy: `git log origin/deploy-state -- dev.json`.
