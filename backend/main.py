import uvicorn
from pathlib import Path
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles

from .api.routes import router

app = FastAPI(title="Douyin Reup API", version="1.0.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(router)

# Optional: Serve frontend locally during development
# Uncomment if running frontend and backend on same server
# web_dir = Path(__file__).resolve().parent.parent / "flutter_ui" / "build" / "web"
# if web_dir.exists():
#     app.mount("/", StaticFiles(directory=str(web_dir), html=True), name="frontend")


if __name__ == "__main__":
    import os
    port = int(os.getenv("PORT", 8000))
    uvicorn.run("backend.main:app", host="0.0.0.0", port=port, reload=False)
