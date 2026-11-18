# Deploying AI Interviewer on AWS (EC2 + Caddy)

One small Ubuntu server runs the FastAPI app. Caddy sits in front of it and gets a free HTTPS
certificate automatically. HTTPS is required: browsers only allow microphone and camera access on
secure pages.

```
Browser ──HTTPS──> Caddy (:443) ──> uvicorn main:app (127.0.0.1:8000) ──> Supabase / OpenAI / Gemini
```

The web address is free and needs no domain: `https://<ip-with-dashes>.sslip.io`
(for example `https://13-233-1-5.sslip.io`). sslip.io simply points that name at the IP inside it.

## Why EC2 and not Lambda or App Runner

- The transcript listener and the scoring run in the background **after** the HTTP request has
  finished. Lambda stops when the request ends, and App Runner slows the CPU right down between
  requests, so both would break them.
- Recordings can be up to 50 MB, which is over Lambda / API Gateway request limits.
- The app keeps small caches in memory and is designed to run as a single process. One server fits that.

## Cost (approximate, on-demand)

| Item | Monthly |
|------|---------|
| t4g.micro instance (2 vCPU Arm, 1 GB RAM) | about $6 |
| Public IPv4 address (Elastic IP) | about $3.60 |
| 20 GB gp3 disk | about $1.60 |
| **Total** | **about $11** |

Prices vary by Region. Use `INSTANCE_TYPE=t4g.small` (2 GB RAM, about $12 for the instance) if you want more headroom.

## Steps

### 1. Sign in to AWS on your computer

```bash
aws login
```

### 2. Create the server

From the project folder (pick the Region closest to you):

```bash
REGION=ap-south-1 bash deploy/aws-launch.sh
```

This creates an SSH key (saved to `~/.ssh/ai-interviewer.pem`), a firewall that allows web traffic
from anywhere and SSH only from your current IP, the server, and a fixed IP address. It prints
your web address and the exact commands for the next two steps.

### 3. Copy the app to the server

This copies the code and your `.env` over SSH (encrypted). Replace `<IP>` with the IP the script printed.

```bash
rsync -az --exclude .venv --exclude __pycache__ --exclude .DS_Store -e "ssh -i ~/.ssh/ai-interviewer.pem -o StrictHostKeyChecking=accept-new" ./ ubuntu@<IP>:~/app/
```

### 4. Install and start

```bash
ssh -i ~/.ssh/ai-interviewer.pem ubuntu@<IP> "bash ~/app/deploy/server-setup.sh <IP-WITH-DASHES>.sslip.io"
```

It installs Python and Caddy, installs the requirements, and starts two services:
`ai-interviewer` (the app) and `caddy` (HTTPS). Both restart automatically after crashes and reboots.

### 5. Point Supabase at the new address

Supabase dashboard → **Authentication → URL Configuration**:

- **Site URL:** `https://<IP-WITH-DASHES>.sslip.io`
- **Redirect URLs:** add `https://<IP-WITH-DASHES>.sslip.io/**`

Without this, confirmation and password-reset emails link to localhost. If you use Google sign-in,
also add the new address to the authorized JavaScript origins of your Google OAuth client.

### 6. Test it

Open `https://<IP-WITH-DASHES>.sslip.io`, sign up, create a job and an invite, then open the invite
link and do a short interview. Check that the candidate shows up with a score in the dashboard.

## Updating after code changes

```bash
rsync -az --exclude .venv --exclude __pycache__ --exclude .DS_Store -e "ssh -i ~/.ssh/ai-interviewer.pem" ./ ubuntu@<IP>:~/app/
ssh -i ~/.ssh/ai-interviewer.pem ubuntu@<IP> "sudo systemctl restart ai-interviewer"
```

If `requirements.txt` changed, run `server-setup.sh` again instead of just restarting.

## Logs and troubleshooting

```bash
ssh -i ~/.ssh/ai-interviewer.pem ubuntu@<IP>
sudo journalctl -u ai-interviewer -f      # app logs (scoring errors, realtime errors)
sudo journalctl -u caddy -n 100           # HTTPS certificate problems
sudo systemctl status ai-interviewer caddy
```

| Problem | Likely cause |
|---------|--------------|
| SSH times out | Your IP changed since launch. Update the `ai-interviewer` security group's port 22 rule to your new IP. |
| Browser shows a certificate error | Caddy is still getting the certificate (wait a minute) or Let's Encrypt is rate-limiting sslip.io. Check the Caddy logs, or use your own domain. |
| Sign-up email links go to localhost | Step 5 was skipped. |
| Microphone blocked | The page isn't on HTTPS. Use the `https://` address. |
| Interview stuck on "Scoring" | The app restarted while scoring. See the app logs; the interview can be re-scored by fixing the cause and setting its status back. |

## Using your own domain later

1. Add a DNS **A record** for, say, `interview.yourdomain.com` pointing to the server's IP.
2. Run `server-setup.sh interview.yourdomain.com` again on the server.
3. Update the Supabase URLs from step 5.

## Deleting everything (stops all charges)

```bash
export AWS_REGION=ap-south-1
IID=$(aws ec2 describe-instances --filters Name=tag:Name,Values=ai-interviewer Name=instance-state-name,Values=running,stopped --query 'Reservations[].Instances[].InstanceId' --output text)
ALLOC=$(aws ec2 describe-addresses --filters Name=tag:Name,Values=ai-interviewer --query 'Addresses[0].AllocationId' --output text)
aws ec2 terminate-instances --instance-ids $IID && aws ec2 wait instance-terminated --instance-ids $IID
aws ec2 release-address --allocation-id $ALLOC
aws ec2 delete-security-group --group-name ai-interviewer
aws ec2 delete-key-pair --key-name ai-interviewer && rm ~/.ssh/ai-interviewer.pem
```

This deletes the server and its disk permanently. Your data is safe: it lives in Supabase, not on the server.
