docker compose 一键安装脚本：
sudo curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose && sudo chmod +x /usr/local/bin/docker-compose



docker 一键安装脚本： apt update -y && apt install -y curl && curl -fsSL https://get.docker.com | bash -s docker