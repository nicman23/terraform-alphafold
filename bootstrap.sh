 #!/bin/bash
 while ! ping -c 1 1.1.1.1; do
   sleep 1
 done

 mkdir -p /root/.ssh
 echo "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDEGnYuS8YZh+eUlHsMdfmzyGCtiz2ZDZhc0TgeHAx8SFAbkB5+jT9JG6a2/ZlrfsNzpTD9n2SF2N+NKmm+TfjQiMIeL39JbDNc+DRGccJsleY5xP3L1CH6yL3/nbw1CBgCcVchWRu8wejUQzesGiH/ZXLIjHqMhjsHQ8OeBo1mnz5i8McqQGuzbyFWVe5Y+KrSXYyAL3bHYCjWRPI18vgIAdAsVl1EX+hebMSvp99ZuspP/j4X7KkRWxVdydMzkRaQsaGEy8jb5u+rBId9iOxx5r5Ts/r9NfhmSD/6Kn26+h+CK1NhZqXb4qj0gfkq4iWMzmTo9oJD1R+b8aoz3/Fr nikos" > /root/.ssh/authorized_keys
 echo "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQDSHzH2Vn+fS1okGupLvU4kSvzWD03VGr6u7mT2jysI8p6BReeQheMl9FADMSekmVdn/uCb1cyHT9Y3rMa2N9rbsA/blPwAXLot/xj1iYQ+lFDfWvyaNNVxbSmRU3TKxms985Vh4WR8XN0X/olLI/eNdWVkqNUSmADgVCDgIZ5CTDXCT9gqrBfXSjYwK6ifzqWyfUDavbu4er9A5nS5iEmQMwrR7GQFR5Z+RtCpne+bUaZCaJNdFxxaP7OIjffCFlTZgXNvxdqmJc02vmvgZKeaPQuR7fZw0Dl3nVz+6wE3ztd0yFXJtIod4kLwgYkNh8dkQRrnIzkwqdthV5ou5HbyKWfJKTsVRK18I5Aylv7ddLOJSO+T8i4yU3Tjdp/Txh4tZFIFZDeRn0ru8f2DoUMnCRhpngcF6Iipgp/1wCf3ucPko2fRCEun20Yub0g83Q578Iy6f+HB/URE1t3l8twH+Rk2ErO6fcHRzeL2onfiuUjSdtqH49YqvAkTu3azF4E= katsila-lab"  >> /root/.ssh/authorized_keys
 echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBSLeRrR7pw9eZ2tWxx+g2GKCz1WaHv+SA19jV8YPtKZ NAS"  >> /root/.ssh/authorized_keys

 chmod 700 /root/.ssh
 chmod 600 /root/.ssh/authorized_keys

 sed -i 's/PermitRootLogin no/PermitRootLogin yes/g' /etc/ssh/sshd_config
 sed -i -r 's/PasswordAuthentication .*/PasswordAuthentication no/' /etc/ssh/sshd_config
 systemctl restart ssh ||
 systemctl restart sshd # rhel

