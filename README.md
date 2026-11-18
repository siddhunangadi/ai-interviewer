# AI Interviewer

AI voice interviews for hiring teams. A company creates a job with its own **evaluation rubric**, sends each candidate a **personal invite link**, and the candidate has a live spoken interview with an AI that has read their resume and GitHub. The interview is recorded, then scored criterion by criterion against the rubric, with evidence from the transcript.

Built with **FastAPI**, **Supabase** (Postgres, Storage, Auth), **OpenAI Realtime**, **Gemini**, and plain **HTML/CSS/JS**.

![Architecture](architecture.svg)

## How it works

**Recruiters** (`/signup`, `/signin`, `/app`)
- Sign up with email and password (or Google, once enabled) and create a company workspace.
- **Jobs:** create a job with a rubric of up to 8 criteria. Each has a name, a description of a strong answer, and a weight; weights add up to 100%. Optional notes tell the interviewer what to focus on.
- **Invites:** create a personal link per candidate. It works once and expires in 7 days. Copy it or open a pre-written email.
- **Candidates:** recording, resume, overall score, per-criterion scores with evidence, strengths, weaknesses and transcript. You only ever see your own company's candidates.
- **Team:** the workspace owner invites HR partners and engineers by email (`/join/<code>`).

**Candidates** (`/i/<code>`): no account. Open the link, upload a resume, talk to the interviewer, submit. Candidates don't see their score; it goes to the hiring team.

**Scoring:** the rubric is copied onto each interview when it starts, so editing a job later never changes past scores. Gemini scores every criterion from 0 to 10 with one sentence of evidence, and the server computes the weighted overall score itself.

## 1. Supabase setup

Run this in the **Supabase SQL Editor**. It is safe to run more than once.

```sql
create table if not exists interviews (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  status text not null default 'Pre',
  score integer not null default 0,
  feedback text
);
alter table interviews add column if not exists candidate_name text;
alter table interviews add column if not exists candidate_email text;
alter table interviews add column if not exists role text not null default 'Software Engineer';
alter table interviews add column if not exists github_url text;
alter table interviews add column if not exists github_metadata jsonb not null default '[]'::jsonb;
alter table interviews add column if not exists resume_text text;
alter table interviews add column if not exists resume_path text;
alter table interviews add column if not exists recording_path text;
alter table interviews add column if not exists strengths jsonb not null default '[]'::jsonb;
alter table interviews add column if not exists weaknesses jsonb not null default '[]'::jsonb;
alter table interviews add column if not exists recommendation text;
alter table interviews add column if not exists error text;
alter table interviews drop constraint if exists interviews_status_check;
alter table interviews add constraint interviews_status_check
  check (status in ('Pre', 'InProgress', 'Scoring', 'Done', 'Failed'));

create table if not exists messages (
  id uuid primary key default gen_random_uuid(),
  interview_id uuid not null references interviews(id) on delete cascade,
  type text not null check (type in ('User', 'Assistant')),
  message text not null,
  created_at timestamptz not null default now()
);

create table if not exists companies (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  created_at timestamptz not null default now()
);
create table if not exists recruiters (
  user_id uuid primary key references auth.users(id) on delete cascade,
  company_id uuid not null references companies(id) on delete cascade,
  full_name text not null,
  email text not null,
  role text not null default 'member' check (role in ('owner', 'member')),
  created_at timestamptz not null default now()
);
create table if not exists jobs (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references companies(id) on delete cascade,
  title text not null,
  focus text,
  rubric jsonb not null default '[]'::jsonb,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);
create table if not exists invites (
  id uuid primary key default gen_random_uuid(),
  token text not null unique,
  company_id uuid not null references companies(id) on delete cascade,
  job_id uuid not null references jobs(id) on delete cascade,
  candidate_name text not null,
  candidate_email text not null,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  used_at timestamptz,
  interview_id uuid references interviews(id) on delete set null
);
create table if not exists team_invites (
  id uuid primary key default gen_random_uuid(),
  token text not null unique,
  company_id uuid not null references companies(id) on delete cascade,
  email text not null,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  used_at timestamptz,
  used_by uuid references auth.users(id) on delete set null
);

alter table interviews add column if not exists company_id uuid references companies(id) on delete cascade;
alter table interviews add column if not exists job_id uuid references jobs(id) on delete set null;
alter table interviews add column if not exists rubric jsonb not null default '[]'::jsonb;
alter table interviews add column if not exists rubric_scores jsonb not null default '[]'::jsonb;

create index if not exists interviews_company_idx on interviews (company_id, created_at desc);
create index if not exists interviews_job_idx on interviews (job_id);
create index if not exists messages_interview_idx on messages (interview_id, created_at);
create index if not exists recruiters_company_idx on recruiters (company_id);
create index if not exists jobs_company_idx on jobs (company_id, created_at desc);
create index if not exists invites_company_idx on invites (company_id, created_at desc);
create index if not exists invites_job_idx on invites (job_id);
create index if not exists team_invites_company_idx on team_invites (company_id);

-- Only the server (secret key) can read or write these tables.
alter table interviews enable row level security;
alter table messages enable row level security;
alter table companies enable row level security;
alter table recruiters enable row level security;
alter table jobs enable row level security;
alter table invites enable row level security;
alter table team_invites enable row level security;

-- Private buckets: files are only reachable through short-lived signed URLs.
drop policy if exists "Public Access Recordings" on storage.objects;
drop policy if exists "Public Access Resumes" on storage.objects;
insert into storage.buckets (id, name, public, file_size_limit)
values ('resumes', 'resumes', false, 5242880),
       ('recordings', 'recordings', false, 52428800)
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit;
```

### Auth settings (Supabase dashboard → Authentication)

1. **URL Configuration:** set **Site URL** to `http://localhost:8000` and add `http://localhost:8000/**` under **Redirect URLs**. When you deploy, add your real domain the same way. Without this, confirmation and password-reset emails link to the wrong address.
2. **Emails:** Supabase's built-in email sender is for testing. It only delivers to your project's team members and sends just a few emails per hour. For real users, add your own SMTP provider (Resend, Amazon SES, Postmark…) under **Emails → SMTP Settings**. For local testing you can instead turn off **Confirm email** under **Sign In / Providers → Email**.
3. **Google sign-in (optional):** enable **Google** under **Sign In / Providers** with a Google Cloud OAuth client. The "Continue with Google" button appears automatically once it is enabled.

## 2. Environment

Copy `.env.example` to `.env` and fill in every value. `SUPABASE_SERVICE_KEY` is the **secret** key (server only). `SUPABASE_PUBLISHABLE_KEY` is the **publishable** key (safe in the browser, used only for signing in).

## 3. Run locally

```bash
.venv/bin/pip install -r requirements.txt
.venv/bin/uvicorn main:app --reload --port 8000
```

- Homepage: `http://localhost:8000`
- Sign up / recruiter app: `http://localhost:8000/signup` → `http://localhost:8000/app`
- Candidate links look like `http://localhost:8000/i/<code>` and are created from a job's page.

Recordings are capped at 50 MB (the Supabase free-tier file limit), roughly 20 minutes of video at the built-in bitrate.
