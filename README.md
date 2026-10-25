# Deploying the TravelMemory MERN Application on AWS with Terraform and Ansible

Application repository: https://github.com/UnpredictablePrashant/TravelMemory

This project provisions AWS infrastructure with **Terraform** and configures and deploys the MERN application with **Ansible**.

---

## 1. Architecture

```
                     Internet
                         |
                 [Internet Gateway]
                         |
 +---------------------- VPC 10.0.0.0/16 ----------------------+
 |                                                             |
 |  Public subnet 10.0.1.0/24          Private subnet 10.0.2.0/24
 |  +---------------------------+      +----------------------+
 |  | Web server (EC2)          |      | DB server (EC2)      |
 |  | Nginx + React build       | ---> | MongoDB 7 (auth on)  |
 |  | Node/Express (pm2) :3001  | 27017| no public IP         |
 |  +---------------------------+      +----------------------+
 |  | NAT Gateway (Elastic IP)  | <--- outbound internet only   |
 |  +---------------------------+                               |
 +-------------------------------------------------------------+
```

How the pieces interact:

- The browser requests the site from **Nginx** on the web server (port 80). Nginx serves the React production build and proxies `/api/` to the Express backend on `localhost:3001`.
- The **Express backend** connects to **MongoDB** on the private IP of the database server (port 27017) using a dedicated application user.
- The **database server** has no public IP. Its security group only accepts SSH and MongoDB traffic from the web server's security group. It reaches the internet (package installs) through the **NAT Gateway**.
- **Ansible** reaches the database server by using the web server as an SSH jump host (bastion).

---

## 2. Repository structure

```
.
├── README.md
├── .gitignore
├── screenshots/
├── terraform/
│   ├── main.tf
│   ├── variables.tf
│   ├── outputs.tf
│   └── terraform.tfvars.example
└── ansible/
    ├── ansible.cfg
    ├── inventory.ini.example
    ├── group_vars/all.yml.example
    ├── site.yml
    └── templates/
        ├── nginx.conf.j2
        ├── backend.env.j2
        └── frontend.env.j2
```

All of these files are already included in this repository. The code is shown below for the report.

---

## 3. Prerequisites

- AWS account and an IAM user with permissions for EC2, VPC, and IAM
- AWS CLI, Terraform >= 1.5, Ansible >= 2.14 (use WSL on Windows)
- An SSH key pair on your machine (`ssh-keygen -t ed25519 -f ~/.ssh/travel_key`)

```bash
aws configure          # access key, secret key, region (e.g. ap-south-1), output json
aws sts get-caller-identity
```

### `.gitignore`

```gitignore
.terraform/
*.tfstate
*.tfstate.*
terraform.tfvars
ansible/inventory.ini
ansible/group_vars/all.yml
*.pem
*.key
.env
```

---

## 4. Part 1 - Terraform

### `terraform/variables.tf`

```hcl
variable "aws_region" {
  type    = string
  default = "ap-south-1"
}

variable "my_ip_cidr" {
  description = "Your public IP in CIDR form, e.g. 203.0.113.10/32"
  type        = string
}

variable "public_key_path" {
  type    = string
  default = "~/.ssh/travel_key.pub"
}

variable "web_instance_type" {
  type    = string
  default = "t3.small" # React build needs more than 1 GB RAM
}

variable "db_instance_type" {
  type    = string
  default = "t3.small"
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "public_subnet_cidr" {
  type    = string
  default = "10.0.1.0/24"
}

variable "private_subnet_cidr" {
  type    = string
  default = "10.0.2.0/24"
}
```

### `terraform/main.tf`

```hcl
terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

data "aws_availability_zones" "available" {
  state = "available"
}

# Ubuntu 22.04 LTS
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
}

# ---------------------------------------------------------------- Network
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags                 = { Name = "travelmemory-vpc" }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidr
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true
  tags                    = { Name = "travelmemory-public" }
}

resource "aws_subnet" "private" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnet_cidr
  availability_zone = data.aws_availability_zones.available.names[0]
  tags              = { Name = "travelmemory-private" }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "travelmemory-igw" }
}

resource "aws_eip" "nat" {
  domain     = "vpc"
  depends_on = [aws_internet_gateway.igw]
  tags       = { Name = "travelmemory-nat-eip" }
}

resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public.id
  depends_on    = [aws_internet_gateway.igw]
  tags          = { Name = "travelmemory-nat" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  tags = { Name = "travelmemory-public-rt" }
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat.id
  }
  tags = { Name = "travelmemory-private-rt" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
}

# --------------------------------------------------------- Security groups
resource "aws_security_group" "web" {
  name        = "travelmemory-web-sg"
  description = "Web server"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "SSH from my IP only"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.my_ip_cidr]
  }
  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "travelmemory-web-sg" }
}

resource "aws_security_group" "db" {
  name        = "travelmemory-db-sg"
  description = "Database server"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "SSH from web server (bastion)"
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.web.id]
  }
  ingress {
    description     = "MongoDB from web server"
    from_port       = 27017
    to_port         = 27017
    protocol        = "tcp"
    security_groups = [aws_security_group.web.id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "travelmemory-db-sg" }
}

# --------------------------------------------------------------- IAM role
data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ec2" {
  name               = "travelmemory-ec2-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

# Session Manager access and CloudWatch metrics/logs
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "cloudwatch" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_iam_instance_profile" "ec2" {
  name = "travelmemory-ec2-profile"
  role = aws_iam_role.ec2.name
}

# ---------------------------------------------------------------- Key pair
resource "aws_key_pair" "deployer" {
  key_name   = "travelmemory-key"
  public_key = file(pathexpand(var.public_key_path))
}

# --------------------------------------------------------------- Instances
resource "aws_instance" "web" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.web_instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.web.id]
  key_name               = aws_key_pair.deployer.key_name
  iam_instance_profile   = aws_iam_instance_profile.ec2.name

  root_block_device {
    volume_size = 20
    encrypted   = true
  }
  metadata_options {
    http_tokens = "required" # IMDSv2
  }
  tags = { Name = "travelmemory-web" }
}

resource "aws_instance" "db" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.db_instance_type
  subnet_id              = aws_subnet.private.id
  vpc_security_group_ids = [aws_security_group.db.id]
  key_name               = aws_key_pair.deployer.key_name
  iam_instance_profile   = aws_iam_instance_profile.ec2.name

  root_block_device {
    volume_size = 20
    encrypted   = true
  }
  metadata_options {
    http_tokens = "required"
  }
  depends_on = [aws_nat_gateway.nat]
  tags       = { Name = "travelmemory-db" }
}
```

### `terraform/outputs.tf`

```hcl
output "web_server_public_ip" {
  description = "Public IP of the web server"
  value       = aws_instance.web.public_ip
}

output "web_server_private_ip" {
  value = aws_instance.web.private_ip
}

output "db_server_private_ip" {
  value = aws_instance.db.private_ip
}
```

### `terraform/terraform.tfvars.example`

```hcl
aws_region      = "ap-south-1"
my_ip_cidr      = "YOUR.PUBLIC.IP.HERE/32"   # find it with: curl ifconfig.me
public_key_path = "~/.ssh/travel_key.pub"
```

### Run Terraform

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars   # then edit my_ip_cidr
terraform init
terraform validate
terraform plan
terraform apply
terraform output web_server_public_ip
```

---

## 5. Part 2 - Ansible

### `ansible/ansible.cfg`

```ini
[defaults]
inventory = inventory.ini
host_key_checking = False
remote_user = ubuntu
private_key_file = ~/.ssh/travel_key
interpreter_python = auto_silent
forks = 5

[privilege_escalation]
become = True
```

### `ansible/inventory.ini.example`

Replace the placeholders with the Terraform outputs.

```ini
[web]
webserver ansible_host=<WEB_PUBLIC_IP>

[db]
dbserver ansible_host=<DB_PRIVATE_IP>

[db:vars]
ansible_ssh_common_args='-o ProxyCommand="ssh -W %h:%p -q -i ~/.ssh/travel_key -o StrictHostKeyChecking=no ubuntu@<WEB_PUBLIC_IP>"'
```

### `ansible/group_vars/all.yml.example`

Copy to `all.yml`, change the passwords, and ideally encrypt with `ansible-vault encrypt group_vars/all.yml`.

```yaml
db_private_ip: "<DB_PRIVATE_IP>"
web_public_ip: "<WEB_PUBLIC_IP>"

mongo_admin_user: admin
mongo_admin_password: "ChangeMeAdmin#123"
mongo_app_user: travelapp
mongo_app_password: "ChangeMeApp#123"
mongo_db_name: travelmemory

app_repo: https://github.com/UnpredictablePrashant/TravelMemory.git
app_dir: /opt/TravelMemory
backend_port: 3001
```

### `ansible/templates/backend.env.j2`

```jinja
PORT={{ backend_port }}
MONGO_URI=mongodb://{{ mongo_app_user }}:{{ mongo_app_password | urlencode }}@{{ db_private_ip }}:27017/{{ mongo_db_name }}?authSource={{ mongo_db_name }}
```

### `ansible/templates/frontend.env.j2`

```jinja
REACT_APP_BACKEND_URL=http://{{ web_public_ip }}/api
```

### `ansible/templates/nginx.conf.j2`

```nginx
server {
    listen 80 default_server;
    server_name _;

    root {{ app_dir }}/frontend/build;
    index index.html;

    server_tokens off;

    location / {
        try_files $uri /index.html;
    }

    # React -> Express: /api/trip  ==>  http://127.0.0.1:3001/trip
    location /api/ {
        proxy_pass http://127.0.0.1:{{ backend_port }}/;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }
}
```

### `ansible/site.yml`

```yaml
---
# ===================================================== Database server
- name: Configure MongoDB on the database server
  hosts: db
  tasks:
    - name: Install prerequisites
      apt:
        name: [gnupg, curl, ca-certificates]
        update_cache: yes

    - name: Add MongoDB GPG key
      shell: |
        curl -fsSL https://pgp.mongodb.com/server-7.0.asc | gpg --dearmor -o /usr/share/keyrings/mongodb-server-7.0.gpg
      args:
        creates: /usr/share/keyrings/mongodb-server-7.0.gpg

    - name: Add MongoDB repository
      apt_repository:
        repo: "deb [arch=amd64 signed-by=/usr/share/keyrings/mongodb-server-7.0.gpg] https://repo.mongodb.org/apt/ubuntu jammy/mongodb-org/7.0 multiverse"
        filename: mongodb-org-7.0
        state: present

    - name: Install MongoDB
      apt:
        name: mongodb-org
        update_cache: yes

    - name: Bind MongoDB to localhost and the private IP
      lineinfile:
        path: /etc/mongod.conf
        regexp: '^\s*bindIp:'
        line: "  bindIp: 127.0.0.1,{{ db_private_ip }}"
      notify: restart mongod

    - name: Start MongoDB (auth not yet enabled, needed to create the first users)
      service:
        name: mongod
        state: started
        enabled: yes

    - name: Flush handlers
      meta: flush_handlers

    - name: Wait for MongoDB
      wait_for:
        port: 27017
        host: 127.0.0.1
        delay: 3

    - name: Create admin and application users (idempotent)
      shell: |
        mongosh --quiet --eval '
          const admin = db.getSiblingDB("admin");
          if (!admin.getUser("{{ mongo_admin_user }}")) {
            admin.createUser({user: "{{ mongo_admin_user }}", pwd: "{{ mongo_admin_password }}",
              roles: [{role: "root", db: "admin"}]});
          }
          const app = db.getSiblingDB("{{ mongo_db_name }}");
          if (!app.getUser("{{ mongo_app_user }}")) {
            app.createUser({user: "{{ mongo_app_user }}", pwd: "{{ mongo_app_password }}",
              roles: [{role: "readWrite", db: "{{ mongo_db_name }}"}]});
          }
          app.createCollection("trips");
        ' 2>&1 || true
      no_log: true
      register: mongo_users
      changed_when: false
      # This only works while auth is still disabled; on re-runs auth is on
      # and the users already exist, so errors are tolerated.

    - name: Enable MongoDB authentication
      blockinfile:
        path: /etc/mongod.conf
        marker: "# {mark} ANSIBLE SECURITY"
        block: |
          security:
            authorization: enabled
      notify: restart mongod

  handlers:
    - name: restart mongod
      service:
        name: mongod
        state: restarted

# ======================================================== Web server
- name: Configure Node.js, the MERN app and Nginx on the web server
  hosts: web
  tasks:
    - name: Install base packages
      apt:
        name: [git, curl, nginx, ca-certificates, gnupg]
        update_cache: yes

    - name: Add NodeSource repository (Node.js 18)
      shell: curl -fsSL https://deb.nodesource.com/setup_18.x | bash -
      args:
        creates: /etc/apt/sources.list.d/nodesource.list

    - name: Install Node.js and npm
      apt:
        name: nodejs
        update_cache: yes

    - name: Install pm2 globally
      npm:
        name: pm2
        global: yes

    - name: Clone the TravelMemory repository
      git:
        repo: "{{ app_repo }}"
        dest: "{{ app_dir }}"
        version: main
        force: yes
      register: repo
      failed_when: false

    - name: Fall back to the master branch if main does not exist
      git:
        repo: "{{ app_repo }}"
        dest: "{{ app_dir }}"
        force: yes
      when: repo is failed

    - name: Create backend .env
      template:
        src: backend.env.j2
        dest: "{{ app_dir }}/backend/.env"
        mode: "0600"

    - name: Create frontend .env
      template:
        src: frontend.env.j2
        dest: "{{ app_dir }}/frontend/.env"
        mode: "0644"

    - name: Install backend dependencies
      npm:
        path: "{{ app_dir }}/backend"

    - name: Install frontend dependencies
      npm:
        path: "{{ app_dir }}/frontend"

    - name: Build the React frontend
      command: npm run build
      args:
        chdir: "{{ app_dir }}/frontend"
      environment:
        NODE_OPTIONS: --max-old-space-size=1536

    - name: Start (or restart) the backend with pm2
      shell: |
        pm2 delete travel-backend || true
        pm2 start index.js --name travel-backend
        pm2 save
      args:
        chdir: "{{ app_dir }}/backend"

    - name: Make pm2 start on boot
      command: pm2 startup systemd -u root --hp /root
      changed_when: false

    - name: Configure Nginx
      template:
        src: nginx.conf.j2
        dest: /etc/nginx/sites-available/travelmemory
      notify: reload nginx

    - name: Enable the Nginx site
      file:
        src: /etc/nginx/sites-available/travelmemory
        dest: /etc/nginx/sites-enabled/travelmemory
        state: link
      notify: reload nginx

    - name: Remove default Nginx site
      file:
        path: /etc/nginx/sites-enabled/default
        state: absent
      notify: reload nginx

    - name: Make sure Nginx is running
      service:
        name: nginx
        state: started
        enabled: yes

  handlers:
    - name: reload nginx
      service:
        name: nginx
        state: reloaded

# =================================================== Security hardening
- name: Harden both servers
  hosts: all
  tasks:
    - name: Install ufw and fail2ban
      apt:
        name: [ufw, fail2ban, unattended-upgrades]
        update_cache: yes

    - name: Disable root login over SSH
      lineinfile:
        path: /etc/ssh/sshd_config
        regexp: '^#?PermitRootLogin'
        line: "PermitRootLogin no"
      notify: restart ssh

    - name: Disable password authentication
      lineinfile:
        path: /etc/ssh/sshd_config
        regexp: '^#?PasswordAuthentication'
        line: "PasswordAuthentication no"
      notify: restart ssh

    - name: Limit SSH retries
      lineinfile:
        path: /etc/ssh/sshd_config
        regexp: '^#?MaxAuthTries'
        line: "MaxAuthTries 3"
      notify: restart ssh

    - name: ufw default deny incoming
      ufw:
        default: deny
        direction: incoming

    - name: ufw default allow outgoing
      ufw:
        default: allow
        direction: outgoing

    - name: ufw allow SSH
      ufw:
        rule: allow
        port: "22"
        proto: tcp

    - name: ufw allow HTTP and HTTPS (web only)
      ufw:
        rule: allow
        port: "{{ item }}"
        proto: tcp
      loop: ["80", "443"]
      when: inventory_hostname in groups['web']

    - name: ufw allow MongoDB from the VPC only (db only)
      ufw:
        rule: allow
        port: "27017"
        proto: tcp
        from_ip: 10.0.0.0/16
      when: inventory_hostname in groups['db']

    - name: Enable ufw
      ufw:
        state: enabled

    - name: Enable fail2ban
      service:
        name: fail2ban
        state: started
        enabled: yes

  handlers:
    - name: restart ssh
      service:
        name: ssh
        state: restarted
```

### Run Ansible

```bash
cd ansible
cp inventory.ini.example inventory.ini         # fill in IPs
cp group_vars/all.yml.example group_vars/all.yml   # fill in IPs and passwords
ansible all -m ping                            # test connectivity (db goes via the web server)
ansible-playbook site.yml --syntax-check
ansible-playbook site.yml
```

Open `http://<WEB_PUBLIC_IP>` in the browser.

> Note: the TravelMemory repo may name its backend variables or the frontend URL file differently from what is assumed here (`backend/.env` with `MONGO_URI` and `PORT`; frontend base URL read from `REACT_APP_BACKEND_URL` or a `frontend/src/url.js` file). Check the repo and adjust the two `.env` templates (and `url.js` if required) before running the playbook.

---

## 6. Verification checklist

| Check | Command / action | Expected |
|---|---|---|
| Terraform outputs | `terraform output` | Web public IP shown |
| SSH to web (your IP only) | `ssh -i ~/.ssh/travel_key ubuntu@<WEB_IP>` | Login works; fails from other IPs |
| SSH to DB via bastion | `ssh -J ubuntu@<WEB_IP> ubuntu@<DB_PRIVATE_IP>` | Login works |
| Mongo requires auth | `mongosh --eval "db.adminCommand('listDatabases')"` on DB | Unauthorized error |
| Backend running | `pm2 status` on web | `travel-backend` online |
| API reachable | `curl http://<WEB_IP>/api/hello` | Response from backend |
| Frontend loads | Open `http://<WEB_IP>` | Travel Memory UI |
| Data persists | Add a trip in the UI, reload | Trip still listed |

Add your screenshots to a `screenshots/` folder and reference them here:

```markdown
![Terraform apply](screenshots/terraform-apply.png)
![Ansible run](screenshots/ansible-run.png)
![Working app](screenshots/app.png)
```

---

## 7. Security measures implemented

- Web SSH restricted to the user's IP; database has no public IP and is only reachable from the web security group
- MongoDB authentication enabled, with separate admin and least-privilege application users; bound to private interfaces
- SSH key pairs only, password login and root login disabled, `MaxAuthTries 3`
- UFW firewall on both hosts plus security groups (defence in depth)
- fail2ban against SSH brute force; unattended security upgrades installed
- Encrypted EBS volumes, IMDSv2 required, IAM role instead of stored AWS keys
- Secrets kept out of Git through `.gitignore` (use Ansible Vault for `all.yml`)

---

## 8. Cleanup

NAT Gateways and Elastic IPs cost money while they exist.

```bash
cd terraform
terraform destroy
```

---

