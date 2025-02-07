# GC-AI: Local Testing Environment

This repository is used for testing the application locally and is intended only for reviewers. The final project will be available on a website.

🚨 **Important:** After starting the project, it is recommended to wait a few minutes to allow the database and the prediction model to fully load. This helps prevent potential connection or initialization errors.

## 🚀 Installation and Execution

### 1️⃣ **Prerequisites**
Before getting started, make sure you have installed:
- [Docker](https://www.docker.com/get-started) 🐳
- [Docker Compose](https://docs.docker.com/compose/install/) (already included in Docker Desktop)

You can check if Docker is installed by running:
```sh
docker --version
```
And for Docker Compose:
```sh
docker compose version
```

### 2️⃣ **Download the Project**
Clone the repository or download the `docker-compose.yml` file into a local folder:
```sh
git clone https://github.com/cvtalrc/GC-AI-environment.git
cd GC-AI-environment
```

### 3️⃣ **Run the Project**
In the same folder where `docker-compose.yml` is located, run:
```sh
docker compose up -d
```
This will download the necessary images and start the services automatically.

### 4️⃣ **Access the Application**
Once the containers are running, you can access:
- **Frontend:** [http://localhost](http://localhost)
- **Backend API:** [http://localhost:5000](http://localhost:5000)
- **Database:** MySQL will be available on port `3307` (user `root`, password `igemparts2024`).

### 5️⃣ **Stop the Application**
To stop the services, use:
```sh
docker compose down
```
To also remove volumes and the database:
```sh
docker compose down -v
```

## 📌 Notes
- No manual configuration is required—everything is ready to run with Docker.