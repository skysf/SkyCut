# 2026-10-29 冒烟清理不能只凭陈旧 PID 停进程

## 症状

测试 App / 假服务已经结束，留下的 pid 文件指向后来复用该 PID 的另一个命令；再次执行 stop 会向无关进程发送 SIGTERM。

## 根因

旧清理代码读出 app.pid / server.pid 就 kill，没有核对它此刻是不是本轮的测试进程。App 改用 LaunchServices 后，早期 app.pid 更不可靠。

## 修复

测试 App 只按独立包的完整可执行路径停止；服务器 PID 必须为数字且 ps 命令同时包含假服务脚本、端口和本轮 assets 目录才停止。收尾删掉两个旧 pid 文件，用户应用及真实服务不在匹配范围。

## 验证

回归启动一个真实的无关 Python sleep 子进程，把其 PID 同时写进两个测试文件，调用生产 run.sh stop；Keychain / defaults / pkill 用无副作用夹具隔离，只观察真实 PID。旧版本明确杀掉子进程（退出 -15，断言变红）；修复后子进程仍活着，测试最后自行清理。未观察或声称用户的其他进程曾受影响。

## 教训 / 防回归

持久 PID 不是进程身份；清理必须核对当前命令和测试目录。长期规矩见 [GUI 冒烟](../testing/gui-smoke-testing.md)四之八。
