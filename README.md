# GC-AI: Local Testing Environment

This repository provides an easy way to test the GC-AI application locally using Docker. Anyone interested in running the project on their machine can follow these simple steps.

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

- Using SSH:
  ```sh
  git clone git@github.com:cvtalrc/GC-AI-environment.git
  cd GC-AI-environment
  ```
  
- Using HTTPS (no SSH key required):
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

🚨 **Important:** After running the above command, please wait **at least 5 minutes** before using the application to ensure the database and model are fully loaded. This helps prevent potential connection or initialization errors. Additionally, once you access the homepage, it is normal for the page to take approximately 10 seconds to load. This delay is expected and occurs due to the system being in test mode.

### 4️⃣ **Access the Application**
Once the containers are running, you can access:
- **Frontend:** [http://localhost:8081](http://localhost:8081)
- **Backend API:** [http://localhost:5001](http://localhost:5001)
- **Database:** MySQL will be available on port `3307` (user `root`, password `igemparts2024`).

### 5️⃣ **Handling Port Conflicts**
If you experience issues due to port conflicts, follow these steps:

#### Check Which Process is Using the Port
Run the following command to see which process is using a specific port:
```sh
netstat -tulnp | grep :<PORT>  # Linux
lsof -i :<PORT>                # macOS
netstat -ano | findstr :<PORT>  # Windows
```
Replace `<PORT>` with the port number causing the conflict (e.g., 5001, 8081, or 3307).

#### Kill the Process Using the Port
Once you identify the process ID (PID), terminate it with:
```sh
kill -9 <PID>  # Linux/macOS
taskkill /PID <PID> /F  # Windows
```
Replace `<PID>` with the actual process ID.

#### Changing Ports (If Necessary)
- To change the **frontend** port, modify the following line in `docker-compose.yml`:
  ```yaml
  ports:
    - "8082:80"  # Change 8081 to another available port
  ```

- To change the **database** port, modify these lines:
  ```yaml
  ports:
    - "3308:3306"  # Change 3307 to another available port
  ```
  
🚨 **The backend must remain on port 5001, as it is preconfigured to use this port. Do not change it.**

### 6️⃣ **Stop the Application**
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
- If you encounter any issues, try restarting Docker and running the commands again.
- If a port conflict occurs, follow the steps above to free the port instead of changing it.

