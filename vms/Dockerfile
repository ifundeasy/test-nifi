FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

# Update package index + upgrade all installed packages to latest security/patch level
RUN apt-get update \
 && apt-get -y full-upgrade \
 && apt-get install -y --no-install-recommends sudo passwd ca-certificates \
 && apt-get -y autoremove --purge \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/*

# Create admin user with password and sudo access
RUN useradd -m -s /bin/bash admin \
 && echo "admin:admin123" | chpasswd \
 && usermod -aG sudo admin \
 && echo "admin ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/admin \
 && chmod 0440 /etc/sudoers.d/admin

USER admin
WORKDIR /home/admin

CMD ["sleep", "infinity"]
