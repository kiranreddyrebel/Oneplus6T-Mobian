sudo tee /etc/systemd/system/waydroid-route-fix.service >/dev/null <<'EOF'
[Unit]
Description=Add default route inside Waydroid
After=waydroid-container.service

[Service]
ExecStart=/usr/local/bin/waydroid-route-fix
Restart=always

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable --now waydroid-route-fix



sudo tee /usr/local/bin/waydroid-route-fix >/dev/null <<'EOF'
#!/bin/sh
while true; do
    if waydroid status 2>/dev/null | grep -q 'Container:.*RUNNING'; then
        echo "ip route replace default via 192.168.240.1 dev eth0" | waydroid shell >/dev/null 2>&1
    fi
    sleep 5
done
EOF
sudo chmod +x /usr/local/bin/waydroid-route-fix
sudo systemctl restart waydroid-route-fix
