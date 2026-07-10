import sys
import os
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



if __name__ == "__main__":
    port = int(os.getenv("PORT", 8765))
    uvicorn.run("backend.main:app", host="0.0.0.0", port=port, reload=True, log_level="info", workers=1)
