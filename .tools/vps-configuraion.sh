# redirect traffic from port 443 to 8010
# sudo iptables -t nat -A PREROUTING -p tcp --dport 443 -j REDIRECT --to-ports 8010

# mark packets coming to port 8010 and drop them
# sudo iptables -t mangle -A PREROUTING -p tcp --dport 8010 -j MARK --set-mark 1
# sudo iptables -A INPUT -m mark --mark 1 -j DROP

# Save the iptables rules to make them persistent across reboots
# sudo service netfilter-persistent save



# ngnix configuration file
# user www-data;
# worker_processes auto;
# worker_cpu_affinity auto;
# pid /run/nginx.pid;
# error_log /var/log/nginx/error.log;
# include /etc/nginx/modules-enabled/*.conf;


# events {
#         worker_connections 768;
#         # multi_accept on;
# }

# http {


#         server {
#                 listen 80 default_server;
#                 listen [::]:80 default_server;

#                 server_name _;

#                 return 301 https://$host$request_uri;
#         }


# }