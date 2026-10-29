LoyalLoop

A Multi-Business Digital Loyalty and Rewards Platform

LoyalLoop is a web-based loyalty platform designed to help businesses build stronger customer relationships through digital loyalty cards, visit stamps, rewards, and special offers. It supports multiple businesses on one platform, with separate dashboards and access permissions for platform administrators, business owners, staff, and customers.

The project is being developed with a focus on usability, business-level data isolation, secure authentication, and a clean, responsive interface.

Table of Contents

- "Overview" (#overview)
- "Key Features" (#key-features)
- "User Roles" (#user-roles)
- "Technology Stack" (#technology-stack)
- "Project Structure" (#project-structure)
- "Prerequisites" (#prerequisites)
- "Installation and Setup" (#installation-and-setup)
- "Environment Configuration" (#environment-configuration)
- "Database and Security" (#database-and-security)
- "Running the Application" (#running-the-application)
- "Development Status" (#development-status)
- "Future Improvements" (#future-improvements)
- "License" (#license)

Overview

Traditional loyalty programs often rely on physical stamp cards or separate systems for each business. LoyalLoop aims to provide a shared digital platform where customers can participate in loyalty programs from multiple businesses using a single account.

Businesses such as cafés, salons, gyms, and other local services can manage their own loyalty programs, while customers can discover participating businesses, collect stamps, track rewards, and view available offers.

Each business should only be able to access its own authorized business data.

Key Features

Multi-Business Support

- Support multiple businesses on a single platform.
- Maintain separate business profiles, loyalty programs, offers, staff, and customer memberships.
- Provide business-specific branding and customer experiences.

Digital Loyalty Cards

- Allow customers to join individual business loyalty programs.
- Support multiple business memberships under one customer account.
- Display membership details and stamp progress.
- Track eligible rewards and redeemed items.

Stamp Collection and Rewards

- Allow authorized staff to record customer stamps.
- Define loyalty rules for individual businesses.
- Support reward redemption by authorized personnel.
- Maintain transaction records for stamps and redemptions.

Business Management

- Allow business owners to configure business details and branding.
- Manage staff access and permissions.
- Configure loyalty programs, reward rules, and offers.
- Provide a foundation for business dashboards and activity tracking.

Offers

- Support business-specific promotional offers.
- Make public offers available for customers to view without necessarily signing in.
- Keep offer management restricted to authorized business users.

Authentication and Authorization

- Use Supabase Authentication for account registration and login.
- Support separate experiences for platform administrators, business owners, staff, and customers.
- Use role and membership checks to control access to protected areas.

User Roles

Role| Intended responsibilities
Platform Admin| Manage and authorize businesses and platform access.
Business Owner| Manage business details, branding, staff, loyalty rules, and offers.
Staff| Register customers, add stamps, and process authorized redemptions.
Customer| Join businesses, view loyalty cards, track stamps, and access rewards and offers.

Access to business information and actions must be restricted according to the authenticated user's permissions.

Technology Stack

- Frontend: HTML, CSS, JavaScript
- Development server and build tooling: Vite
- Backend services: Supabase
- Authentication: Supabase Auth
- Database: PostgreSQL through Supabase
- Database security: PostgreSQL Row Level Security (RLS)
- Version control: Git and GitHub

Project Structure

The project includes frontend pages, application scripts, styling, and Supabase database configuration.

Loyalloop/
├── admin/
│   └── dashboard/
├── owner/
│   └── dashboard/
├── staff/
│   └── dashboard/
├── customer/
│   ├── dashboard/
│   └── business/
├── supabase/
│   ├── migrations/
│   ├── tests/
│   └── seed.sql
├── index.html
├── login.html
├── register.html
├── app.js
├── supabase.js
├── .env.example
├── .gitignore
├── package.json
└── README.md

This is a simplified overview. Refer to the repository for the complete directory structure.

Prerequisites

Install the following before running the application:

- "Node.js" (https://nodejs.org/) with npm
- "Git" (https://git-scm.com/)
- "Visual Studio Code" (https://code.visualstudio.com/) or another code editor
- A "Supabase" (https://supabase.com/) account and project

Installation and Setup

1. Clone the Repository

git clone https://github.com/abhiramipoornimma/Loyalloop.git
cd Loyalloop

If you already have the project locally, open its existing folder instead.

2. Install Dependencies

npm install

3. Configure Environment Variables

Create a ".env.local" file in the project root. Refer to ".env.example" and the variable names used by the application to configure the required Supabase URL and publishable/anonymous key.

Do not copy real credentials into this README or commit ".env.local" to Git.

4. Configure Supabase

- Create or open your Supabase project.
- Verify the project URL and public client key.
- Apply the database migrations in the "supabase/migrations/" directory using the project's established migration workflow.
- Review the database policies and authorization tests before using real customer data.

5. Start the Development Server

npm run dev

Vite will display a local development URL in the terminal, commonly "http://localhost:5173/". Open the URL shown by your terminal in a browser.

Environment Configuration

Environment variable names must match those referenced by the existing frontend code.

Typical configuration values include:

Variable| Purpose
Supabase project URL| Identifies the Supabase project.
Supabase publishable or anonymous key| Allows the frontend to communicate with Supabase under configured access policies.

Use ".env.example" to document the exact variable names required by the application.

Never expose a Supabase service-role key or other secret credentials in frontend JavaScript, public environment variables, GitHub commits, or screenshots. A private repository does not replace proper secret management.

Database and Security

LoyalLoop uses Supabase and PostgreSQL to support authentication, business records, loyalty memberships, stamp transactions, offers, and reward redemptions.

The database configuration includes migrations and Row Level Security policies.

Security goals include:

- Restricting business data to authorized users.
- Preventing users from accessing another business's records by changing URLs or client requests.
- Validating roles and business memberships at the database level.
- Protecting administrative actions.
- Keeping privileged credentials on trusted server-side systems only.
- Testing authorization policies before production deployment.

Frontend visibility checks alone are not sufficient security. Sensitive operations must be enforced by database policies or trusted server-side authorization.

Running the Application

For local development:

1. Open the project folder in VS Code.
2. Open a terminal in the project directory.
3. Run "npm install" if dependencies have not been installed.
4. Confirm that the local environment variables are configured.
5. Run "npm run dev".
6. Open the URL printed by Vite.

Use a test Supabase project and non-production data while development is in progress.

Development Status

Status: Under active development.

The project contains the frontend, Supabase configuration, database migrations, and authentication integration. Some dashboard workflows and business operations may still require implementation, integration, and end-to-end testing.

Before production use, verify registration, login, role assignment, business onboarding, customer enrollment, stamp collection, reward redemption, offers, and cross-business access restrictions.

Future Improvements

Potential improvements include:

- Completing role-based dashboard workflows.
- Connecting all dashboard actions to persistent database records.
- Improving customer enrollment and business discovery.
- Completing stamp and reward redemption flows.
- Adding comprehensive automated authorization tests.
- Improving accessibility and mobile responsiveness.
- Preparing deployment configuration and production monitoring.

Contributing

This repository is currently under development. Changes should preserve existing project conventions, database security policies, and the separation of data between businesses.

License

No license has been specified yet. All rights are reserved by default unless a license is added to the repository.