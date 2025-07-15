#!/bin/bash
set -e # 任何命令失败时立即退出脚本

echo "🚀 Claude Code 安装与配置脚本"

# --- 函数定义 ---

# 函数：检查并安装 Node.js (使用 nvm)
install_nodejs() {
    local platform=$(uname -s)
    echo "🔍 检查 Node.js 安装..."

    if command -v node &>/dev/null; then
        current_version=$(node -v | sed 's/v//')
        major_version=$(echo "$current_version" | cut -d. -f1)
        if [ "$major_version" -ge 18 ]; then
            echo "✅ Node.js 已安装，版本为 v$current_version (>= v18)。"
            return 0
        else
            echo "⚠️ Node.js v$current_version 已安装，但版本低于 v18。将升级..."
        fi
    else
        echo "❌ Node.js 未找到。将安装..."
    fi

    case "$platform" in
        Linux|Darwin)
            echo "🚀 正在安装 Node.js (通过 nvm) 在 Unix/Linux/macOS 上..."
            if [ -d "$HOME/.nvm" ]; then
                echo "NVM 文件夹已存在，跳过下载，尝试加载 NVM..."
            else
                echo "📥 下载并安装 nvm..."
                curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash
            fi

            # 确保 nvm 已加载，即使脚本非交互式运行
            export NVM_DIR="$HOME/.nvm"
            [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"  # This loads nvm
            [ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion" # This loads nvm bash_completion

            if ! command -v nvm &>/dev/null; then
                echo "❌ 无法加载 nvm。请检查您的网络连接或手动安装 nvm。"
                exit 1
            fi

            echo "📦 下载并安装 Node.js v22..."
            nvm install 22 || { echo "❌ Node.js v22 安装失败。请检查您的网络连接。"; exit 1; }
            nvm use 22 || { echo "❌ 无法切换到 Node.js v22。"; exit 1; }
            nvm alias default 22 # 设置v22为默认版本

            echo -n "✅ Node.js 安装完成! 版本: "
            node -v
            echo -n "✅ npm 版本: "
            npm -v
            ;;
        *)
            echo "❌ 不支持的平台: $platform。请手动安装 Node.js (v18 或更高版本)。"
            exit 1
            ;;
    esac
}

# 函数：检查并安装 Claude Code NPM 包
install_claude_code() {
    echo "🔍 检查 Claude Code (claude) 安装..."
    if command -v claude &>/dev/null; then
        echo "✅ Claude Code 已安装: $(claude --version 2>/dev/null || echo '版本未知')"
    else
        echo "❌ Claude Code 未找到。正在安装..."
        if ! command -v npm &>/dev/null; then
            echo "错误: npm 未安装或未在 PATH 中。请确保 Node.js 正确安装。"
            exit 1
        fi
        echo "安装 Claude Code via npm..."
        if ! npm install -g @anthropic-ai/claude-code; then
            echo "❌ 错误: 安装 Claude Code 失败。"
            exit 1
        fi
        echo "✅ Claude Code 安装成功。"
    fi
}

# 函数：配置 Claude Code 跳过首次启动向导
skip_onboarding() {
    echo "⚙️ 配置 Claude Code 跳过首次启动向导..."
    node_script='
        const os = require("os");
        const path = require("path");
        const fs = require("fs");
        const homeDir = os.homedir();
        const filePath = path.join(homeDir, ".claude.json");
        try {
            let content = {};
            if (fs.existsSync(filePath)) {
                content = JSON.parse(fs.readFileSync(filePath, "utf-8"));
            }
            fs.writeFileSync(filePath, JSON.stringify({ ...content, hasCompletedOnboarding: true }, null, 2), "utf-8");
            console.log("✅ .claude.json 已更新以跳过向导。");
        } catch (error) {
            console.error("❌ 错误：无法更新 .claude.json:", error.message);
        }
    '
    node -e "$node_script"
}

# 函数：使用 settings.json 配置自部署服务
configure_settings_json_self_deployed() {
    echo "⚙️ 设置 Claude Code 配置 (通过 ~/.claude/settings.json)..."
    CLAUDE_DIR="$HOME/.claude"
    SETTINGS_FILE="$CLAUDE_DIR/settings.json"

    if [ ! -d "$CLAUDE_DIR" ]; then
        mkdir -p "$CLAUDE_DIR"
        echo "创建目录: $CLAUDE_DIR"
    fi

    # 定义自部署服务的API信息
    SELF_DEPLOYED_API_KEY="sk-jn0fhoMxvA8bk2SWPLgeolqAXriBPIc8" # 这是一个占位符key
    SELF_DEPLOYED_BASE_URL="https://code.fkclaude.com/api"

    if [ -f "$SETTINGS_FILE" ]; then
        echo "✅ settings.json 已存在。正在更新 API 配置..."
        cp "$SETTINGS_FILE" "$SETTINGS_FILE.backup"
        echo "创建备份: $SETTINGS_FILE.backup"

        # 尝试使用 jq 进行安全更新
        if command -v jq &>/dev/null; then
            echo "使用 jq 更新 settings.json..."
            jq_script='.env.ANTHROPIC_API_KEY_OLD = (.env.ANTHROPIC_API_KEY // null) |
                         .env.ANTHROPIC_BASE_URL_OLD = (.env.ANTHROPIC_BASE_URL // null) |
                         .env.ANTHROPIC_API_KEY = "'"$SELF_DEPLOYED_API_KEY"'" |
                         .env.ANTHROPIC_BASE_URL = "'"$SELF_DEPLOYED_BASE_URL"'" |
                         .apiKeyHelper = "echo \"'"$SELF_DEPLOYED_API_KEY"'\""'

            if ! jq "$jq_script" "$SETTINGS_FILE" > "$SETTINGS_FILE.tmp" && mv "$SETTINGS_FILE.tmp" "$SETTINGS_FILE"; then
                echo "❌ 错误: 使用 jq 更新 settings.json 失败。"
                echo "请检查文件权限或手动编辑: $SETTINGS_FILE"
                exit 1
            fi
            echo "✅ 已更新现有设置文件，旧值已备份到 *_OLD 字段。"
        elif command -v python3 &>/dev/null; then
            echo "jq 未找到，尝试使用 python3 更新 settings.json..."
            python_script="
import json
import sys
import os

settings_file = os.path.expanduser('$SETTINGS_FILE')
try:
    with open(settings_file, 'r') as f:
        data = json.load(f)
except json.JSONDecodeError:
    print(f'警告: {settings_file} 不是有效的 JSON。将覆盖。')
    data = {}

if 'env' not in data:
    data['env'] = {}
if 'permissions' not in data:
    data['permissions'] = {'allow': [], 'deny': []}

# Backup old values
if 'ANTHROPIC_API_KEY' in data['env']:
    data['env']['ANTHROPIC_API_KEY_OLD'] = data['env']['ANTHROPIC_API_KEY']
if 'ANTHROPIC_BASE_URL' in data['env']:
    data['env']['ANTHROPIC_BASE_URL_OLD'] = data['env']['ANTHROPIC_BASE_URL']

# Set new values
data['env']['ANTHROPIC_API_KEY'] = '$SELF_DEPLOYED_API_KEY'
data['env']['ANTHROPIC_BASE_URL'] = '$SELF_DEPLOYED_BASE_URL'
data['apiKeyHelper'] = 'echo \\\'$SELF_DEPLOYED_API_KEY\\\''

with open(settings_file, 'w') as f:
    json.dump(data, f, indent=2)
print(f'✅ 已使用 Python 更新 {settings_file}。')
"
            if ! python3 -c "$python_script"; then
                echo "❌ 错误: 使用 python3 更新 settings.json 失败。"
                echo "请检查文件权限或手动编辑: $SETTINGS_FILE"
                exit 1
            fi
        else
            echo "⚠️ 警告: 既未找到 jq 也未找到 python3。将直接覆盖 settings.json 文件。"
            cat > "$SETTINGS_FILE" << EOF
{
  "env": {
    "ANTHROPIC_API_KEY": "$SELF_DEPLOYED_API_KEY",
    "ANTHROPIC_BASE_URL": "$SELF_DEPLOYED_BASE_URL"
  },
  "permissions": {
    "allow": [],
    "deny": []
  },
  "apiKeyHelper": "echo '$SELF_DEPLOYED_API_KEY'"
}
EOF
            echo "✅ 已覆盖 settings.json。"
        fi
    else
        echo "创建新的 settings.json..."
        cat > "$SETTINGS_FILE" << EOF
{
  "env": {
    "ANTHROPIC_API_KEY": "$SELF_DEPLOYED_API_KEY",
    "ANTHROPIC_BASE_URL": "$SELF_DEPLOYED_BASE_URL"
  },
  "permissions": {
    "allow": [],
    "deny": []
  },
  "apiKeyHelper": "echo '$SELF_DEPLOYED_API_KEY'"
}
EOF
        echo "✅ 新的 settings.json 已创建。"
    fi
    echo "配置完成! 设置保存到: $SETTINGS_FILE"
}

# 函数：使用环境变量配置 Moonshot 服务
configure_env_vars_moonshot() {
    echo "🔑 请输入您的 Moonshot API key:"
    echo "   您可以从这里获取您的 API key: https://platform.moonshot.cn/console/api-keys"
    echo "   注意: 输入将被隐藏。请直接粘贴您的 API key。"
    echo ""
    read -s MOONSHOT_API_KEY
    echo ""

    if [ -z "$MOONSHOT_API_KEY" ]; then
        echo "⚠️ API key 不能为空。请重新运行脚本并提供有效的 Key。"
        exit 1
    fi

    # 检测当前 shell 并确定 RC 文件
    local current_shell=$(basename "$SHELL")
    local rc_file=""
    case "$current_shell" in
        bash)
            rc_file="$HOME/.bashrc"
            ;;
        zsh)
            rc_file="$HOME/.zshrc"
            ;;
        fish)
            rc_file="$HOME/.config/fish/config.fish"
            ;;
        *)
            echo "🤔 未能识别您的 shell ($current_shell)。将尝试修改 $HOME/.profile。"
            rc_file="$HOME/.profile"
            ;;
    esac

    echo "📝 正在将环境变量添加到 $rc_file..."
    # 检查变量是否已存在以避免重复
    if [ -f "$rc_file" ] && (grep -q "ANTHROPIC_BASE_URL=https://api.moonshot.cn/anthropic/" "$rc_file" || grep -q "ANTHROPIC_API_KEY=" "$rc_file"); then
        echo "⚠️ 环境变量已存在于 $rc_file 中。跳过添加以避免重复。"
        echo "如果您需要更新 Key，请手动编辑 $rc_file 文件。"
    else
        # 附加新条目
        echo "" >> "$rc_file"
        echo "# Claude Code Moonshot 环境变量" >> "$rc_file"
        echo "export ANTHROPIC_BASE_URL=https://api.moonshot.cn/anthropic/" >> "$rc_file"
        echo "export ANTHROPIC_API_KEY=$MOONSHOT_API_KEY" >> "$rc_file"
        echo "✅ 环境变量已添加到 $rc_file"
    fi
    echo "配置完成! 环境变量已设置。"
    echo "重要: Moonshot 配置通过环境变量设置，这将覆盖 ~/.claude/settings.json 中的任何配置。"
}

# --- 主脚本逻辑 ---

# 1. 检查并安装 Node.js
install_nodejs

# 2. 检查并安装 Claude Code
install_claude_code

# 3. 配置 Claude Code 跳过首次启动向导
skip_onboarding

# 4. 提示用户选择配置方式
echo ""
echo "--- 选择 Claude Code 的配置方式 ---"
echo "1. 使用 ~/.claude/settings.json 配置 (适用于自部署服务或预设API Key)"
echo "2. 使用环境变量配置 (适用于 Moonshot AI，需要您的API Key)"
echo ""
read -p "请输入您的选择 (1 或 2) [默认: 1]: " config_choice
config_choice=${config_choice:-1} # 默认选择 1

if [[ "$config_choice" == "1" ]]; then
    configure_settings_json_self_deployed
elif [[ "$config_choice" == "2" ]]; then
    configure_env_vars_moonshot
else
    echo "无效的选择 '$config_choice'。将使用默认选项 '1' (settings.json) 进行配置。"
    configure_settings_json_self_deployed
fi

echo ""
echo "🎉 安装和配置已完成！"
echo ""
echo "🚀 要使环境变量生效 (如果您选择了 Moonshot 配置)，请执行以下操作之一:"
echo "   1. 重新启动您的终端。"
echo "   2. 在当前终端中运行 'source $(basename "$rc_file")' 或 'source $HOME/.profile' (取决于您的shell)。"
echo ""
echo "✨ 然后您就可以开始使用 Claude Code 了:"
echo "   claude"
echo ""
