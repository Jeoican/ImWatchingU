"""ImWatchingU —— 社媒账号变更监控。

监控指定账号在多个平台的公开数据变化：
  * 网易云音乐：歌单内歌曲的增删
  * 微博 / 抖音 / 小红书：粉丝数、关注数等数值指标
  * 可选：精确到人的关注 / 取关列表

对外入口：
  * 命令行：``python -m imwatching.cli <子命令>``
  * Web 面板：``python -m imwatching.webapp``
  * 定时调度：``python -m imwatching.scheduler``
"""

__version__ = "1.0.0"
__all__ = ["__version__"]
