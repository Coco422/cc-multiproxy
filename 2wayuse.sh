#!/bin/bash
set -e # 任何命令失败时立即退出脚本

echo "🚀 Claude Code 安装与配置脚本"

# --- 全局变量用于存储 Shell 配置文件路径 ---
# 在脚本结束时用于提示用户 source 命令
SHELL_RC_FILE=""
SCRIPT_START_TIME=$(date +"%Y%m%d%H%M%S") # 用于备份文件名，确保唯一性

# --- 函数定义 ---

# 函数：获取用户的 Shell 配置文件路径
get_shell_rc_file() {
    local current_shell=$(basename "$SHELL")
    case "$current_shell" in
        bash)
            echo "$HOME/.bashrc"
            ;;
        zsh)
            echo "$HOME/.zshrc"
            ;;
        fish)
            # Fish shell uses config.fish, and it sources it automatically
            # but for consistency in message, we still list it.
            echo "$HOME/.config/fish/config.fish"
            ;;
        *)
            # Fallback for other shells or if SHELL is not set properly
            # .profile is a common fallback, though .bash_profile might be used for login shells
            echo "$HOME/.profile"
            ;;
    esac
}

# 函数：创建文件备份
backup_file() {
    local file_path="$1"
    if [ -f "$file_path" ]; then
        local backup_path="${file_path}.${SCRIPT_START_TIME}.bak"
        cp "$file_path" "$backup_path"
        echo "🔄 已创建备份: $backup_path"
    fi
}

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
            echo "⚠️ Node.js v$current_version 已安装，但版本低于 v18。将尝试升级到 v22..."
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
                # Use --no-installation-profile to prevent it from modifying .bashrc/.zshrc during install
                # We handle source manually here and in the final message.
                if ! curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash --no-installation-profile; then
                    echo "❌ nvm 安装失败。请检查您的网络连接或权限。"
                    return 1 # Indicate failure
                fi
            fi

            # 确保 nvm 已加载，即使脚本非交互式运行
            export NVM_DIR="$HOME/.nvm"
            [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"  # This loads nvm
            [ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion" # This loads nvm bash_completion

            if ! command -v nvm &>/dev/null; then
                echo "❌ 无法加载 nvm。请检查您的网络连接或手动安装 nvm。"
                return 1
            fi

            echo "📦 下载并安装 Node.js v22..."
            nvm install 22 || { echo "❌ Node.js v22 安装失败。请检查您的网络连接。"; return 1; }
            nvm use 22 || { echo "❌ 无法切换到 Node.js v22。"; return 1; }
            nvm alias default 22 # 设置v22为默认版本

            echo -n "✅ Node.js 安装完成! 版本: "
            node -v
            echo -n "✅ npm 版本: "
            npm -v
            ;;
        *)
            echo "❌ 不支持的平台: $platform。请手动安装 Node.js (v18 或更高版本)。"
            return 1
            ;;
    esac
    return 0
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
            return 1
        fi
        echo "安装 Claude Code via npm..."
        if ! npm install -g @anthropic-ai/claude-code; then
            echo "❌ 错误: 安装 Claude Code 失败。"
            return 1
        fi
        echo "✅ Claude Code 安装成功。"
    fi
    return 0
}

# 函数：配置 Claude Code 跳过首次启动向导
skip_onboarding() {
    echo "⚙️ 配置 Claude Code 跳过首次启动向导..."
    # Explicitly require modules for robustness, even if node --eval can sometimes infer
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
            process.exit(1); // Exit node script if error
        }
    '
    if ! node -e "$node_script"; then
        echo "❌ 无法更新 .claude.json。请手动检查文件权限或内容。"
        # Do not exit script here, this is a minor configuration, not critical for core functionality.
        return 1
    fi
    return 0
}

# 函数：重置 Claude Code 首次启动向导配置 (用于 clear 后的重置)
clear_onboarding() {
    echo "⚙️ 重置 Claude Code 首次启动向导配置..."
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
                delete content.hasCompletedOnboarding; // Remove the property
                fs.writeFileSync(filePath, JSON.stringify(content, null, 2), "utf-8");
                console.log("✅ .claude.json 已更新以重置向导。");
            } else {
                console.log("ℹ️ .claude.json 文件不存在，无需重置。");
            }
        } catch (error) {
            console.error("❌ 错误：无法更新 .claude.json:", error.message);
            process.exit(1);
        }
    '
    if ! node -e "$node_script"; then
        echo "❌ 无法重置 .claude.json。请手动检查文件权限或内容。"
        return 1
    fi
    return 0
}

# 函数：使用 settings.json 配置自部署服务
configure_settings_json_self_deployed() {
    echo "⚙️ 设置 Claude Code 配置 (通过 ~/.claude/settings.json)..."
    CLAUDE_DIR="$HOME/.claude"
    SETTINGS_FILE="$CLAUDE_DIR/settings.json"

    # Define the self-deployed API info
    # This is a placeholder key, please modify according to your actual self-deployed service
    SELF_DEPLOYED_API_KEY="sk-jn0fhoMxvA8bk2SWPLgeolqAXriBPIc8"
    SELF_DEPLOYED_BASE_URL="https://code.fkclaude.com/api"

    if [ ! -d "$CLAUDE_DIR" ]; then
        mkdir -p "$CLAUDE_DIR"
        echo "创建目录: $CLAUDE_DIR"
    fi

    if [ -f "$SETTINGS_FILE" ]; then
        echo "✅ settings.json 已存在。正在尝试更新 API 配置..."
        backup_file "$SETTINGS_FILE" # Backup before any modification

        # Attempt to use jq for robust update
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
                return 1
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
except (json.JSONDecodeError, FileNotFoundError):
    print(f'警告: {settings_file} 不存在或不是有效的 JSON。将尝试创建新结构。')
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
data['apiKeyHelper'] = 'echo \\'$SELF_DEPLOYED_API_KEY\\''
with open(settings_file, 'w') as f:
    json.dump(data, f, indent=2)
print(f'✅ 已使用 Python 更新 {settings_file}。')
"
            if ! python3 -c "$python_script"; then
                echo "❌ 错误: 使用 python3 更新 settings.json 失败。"
                echo "请检查文件权限或手动编辑: $SETTINGS_FILE"
                return 1
            fi
        else
            echo "⚠️ 警告: 既未找到 jq 也未找到 python3。"
            echo "文件 $SETTINGS_FILE 已存在，但无法自动合并配置。请手动编辑此文件。"
            echo "要设置自部署服务，请确保以下内容存在于 'env' 字段:"
            echo "  \"ANTHROPIC_API_KEY\": \"$SELF_DEPLOYED_API_KEY\","
            echo "  \"ANTHROPIC_BASE_URL\": \"$SELF_DEPLOYED_BASE_URL\""
            echo "  \"apiKeyHelper\": \"echo '$SELF_DEPLOYED_API_KEY'\""
            echo "您可以手动删除 $SETTINGS_FILE 后再运行脚本以重新生成。"
            return 1 # Indicate failure to merge
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
    return 0
}

# 函数：移除 Moonshot 环境变量
remove_moonshot_env_vars() {
    SHELL_RC_FILE=$(get_shell_rc_file)
    if [ -f "$SHELL_RC_FILE" ]; then
        if grep -q "# >>> CLAUDE_CODE_ENV_START <<<" "$SHELL_RC_FILE"; then
            echo "🗑️ 正在从 $SHELL_RC_FILE 中移除 Claude Code Moonshot 环境变量..."
            backup_file "$SHELL_RC_FILE" # Backup before removing
            # Use sed to remove the block between markers
            if sed -i '/# >>> CLAUDE_CODE_ENV_START <<</,/# >>> CLAUDE_CODE_ENV_END <<</d' "$SHELL_RC_FILE"; then
                echo "✅ 环境变量已成功移除。"
                echo "ℹ️ 请重新启动您的终端或运行 'source $SHELL_RC_FILE' 以使更改生效。"
            else
                echo "❌ 错误: 无法移除环境变量。请手动检查 $SHELL_RC_FILE。"
                return 1
            fi
        else
            echo "ℹ️ $SHELL_RC_FILE 中未找到 Claude Code Moonshot 环境变量块。"
        fi
    else
        echo "ℹ️ 配置文件 $SHELL_RC_FILE 不存在。"
    fi
    return 0
}

# 函数：使用环境变量配置 Moonshot 服务
configure_env_vars_moonshot() {
    SHELL_RC_FILE=$(get_shell_rc_file) # 获取 Shell 配置文件路径

    local env_vars_exist=false
    if [ -f "$SHELL_RC_FILE" ] && grep -q "# >>> CLAUDE_CODE_ENV_START <<<" "$SHELL_RC_FILE"; then
        env_vars_exist=true
        echo "⚠️ 检测到 $SHELL_RC_FILE 中已存在 Moonshot 环境变量配置。"
        read -p "您想更新这些配置吗？(y/N): " update_choice
        update_choice=${update_choice:-N}
        if [[ "$update_choice" =~ ^[Nn]$ ]]; then
            echo "ℹ️ 跳过更新环境变量。如果您需要更改，请手动编辑 $SHELL_RC_FILE。"
            return 0
        fi
    fi

    echo "🔑 请输入您的 Moonshot API key:"
    echo "   您可以从这里获取您的 API key: https://platform.moonshot.cn/console/api-keys"
    echo "   注意: 输入将被隐藏。请直接粘贴您的 API key。"
    echo ""
    read -s MOONSHOT_API_KEY
    echo ""

    if [ -z "$MOONSHOT_API_KEY" ]; then
        echo "⚠️ API key 不能为空。中止配置。"
        return 1
    fi

    echo "📝 正在将环境变量添加到 $SHELL_RC_FILE..."
    backup_file "$SHELL_RC_FILE" # Always backup before modifying RC file

    if "$env_vars_exist"; then
        # If updating, first remove the old block
        if ! remove_moonshot_env_vars; then
            echo "❌ 无法移除旧的 Moonshot 环境变量。请手动清理后再重试。"
            return 1
        fi
        # Re-source NVM if it was loaded, as remove_moonshot_env_vars might have modified the RC file
        # and subsequent NVM commands might need it. This is defensive.
        export NVM_DIR="$HOME/.nvm"
        [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
        [ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"
    fi

    # Append new entries with markers
    cat >> "$SHELL_RC_FILE" << EOF

# >>> CLAUDE_CODE_ENV_START <<<
# Claude Code Moonshot 环境变量配置 (由安装脚本添加)
export ANTHROPIC_BASE_URL="https://api.moonshot.cn/anthropic/"
export ANTHROPIC_API_KEY="$MOONSHOT_API_KEY"
# >>> CLAUDE_CODE_ENV_END <<<
EOF
    echo "✅ 环境变量已添加到 $SHELL_RC_FILE"
    echo "配置完成! 环境变量已设置。"
    echo "重要: Moonshot 配置通过环境变量设置，这将覆盖 ~/.claude/settings.json 中的任何配置。"
    return 0
}

# 函数：执行安装和配置流程
perform_install_and_configure() {
    echo "--- 开始安装和配置 Claude Code ---"
    # 1. 检查并安装 Node.js
    install_nodejs || { echo "❌ 安装 Node.js 失败，中止。"; exit 1; }
    # 2. 检查并安装 Claude Code
    install_claude_code || { echo "❌ 安装 Claude Code NPM 包失败，中止。"; exit 1; }
    # 3. 配置 Claude Code 跳过首次启动向导
    skip_onboarding || { echo "❌ 配置跳过向导失败，但通常不影响主要功能。"; }

    # 4. 提示用户选择配置方式
    echo ""
    echo "--- 选择 Claude Code 的配置方式 ---"
    echo "1. 使用 ~/.claude/settings.json 配置 (适用于自部署服务或预设API Key)"
    echo "2. 使用环境变量配置 (适用于 Moonshot AI，需要您的API Key，环境变量将覆盖settings.json)"
    echo ""
    read -p "请输入您的选择 (1 或 2) [默认: 1]: " config_choice
    config_choice=${config_choice:-1} # 默认选择 1

    CONFIG_TYPE_SELECTED="settings_json" # 标记选择了哪种配置方式
    if [[ "$config_choice" == "1" ]]; then
        configure_settings_json_self_deployed || { echo "❌ 配置 settings.json 失败，中止。"; exit 1; }
    elif [[ "$config_choice" == "2" ]]; then
        configure_env_vars_moonshot || { echo "❌ 配置环境变量失败，中止。"; exit 1; }
        CONFIG_TYPE_SELECTED="env_vars"
    else
        echo "无效的选择 '$config_choice'。将使用默认选项 '1' (settings.json) 进行配置。"
        configure_settings_json_self_deployed || { echo "❌ 配置 settings.json 失败，中止。"; exit 1; }
    fi

    echo ""
    echo "🎉 安装和配置已完成！"
    echo ""

    # 根据选择的配置方式，给出不同的提示
    if [[ "$CONFIG_TYPE_SELECTED" == "env_vars" ]]; then
        FINAL_RC_FILE=$(get_shell_rc_file) # 确保获取最新的 Shell RC 文件路径
        echo "🔄 要使环境变量生效，您需要执行以下操作之一:"
        echo "   1. 重新启动您的终端。"
        # For fish shell, config.fish is sourced automatically on new shell,
        # so 'source' command is slightly different or less common.
        if [ "$(basename "$FINAL_RC_FILE")" = "config.fish" ]; then
            echo "   2. 对于 Fish shell，通常不需要手动 'source'，新终端会自动加载。"
            echo "      如果需要，可以运行 'source $FINAL_RC_FILE' 或 'fish_update_completions'。"
        else
            echo "   2. 在当前终端中运行以下命令:"
            echo "      source $FINAL_RC_FILE"
        fi
    else
        echo "配置已写入到 ~/.claude/settings.json 文件。"
        echo "通常不需要额外的 'source' 命令。新开终端即可生效。"
    fi
    echo ""
    echo "✨ 然后您就可以开始使用 Claude Code 了:"
    echo "   claude"
    echo ""
}

# 函数：清理配置
clear_configuration() {
    echo "--- 开始清理 Claude Code 配置 ---"
    echo "1. 清理 ~/.claude/settings.json 文件..."
    CLAUDE_DIR="$HOME/.claude"
    SETTINGS_FILE="$CLAUDE_DIR/settings.json"
    CLAUDERC_FILE="$HOME/.claude.json" # onboarding file

    if [ -f "$SETTINGS_FILE" ]; then
        backup_file "$SETTINGS_FILE"
        rm "$SETTINGS_FILE"
        echo "✅ $SETTINGS_FILE 已删除。"
    else
        echo "ℹ️ $SETTINGS_FILE 不存在，无需清理。"
    fi

    echo "2. 重置 Claude Code 首次启动向导配置..."
    clear_onboarding || { echo "❌ 重置 onboarding 失败，请手动检查 $CLAUDERC_FILE。"; }

    echo "3. 清理 Moonshot 环境变量..."
    remove_moonshot_env_vars || { echo "❌ 清理环境变量失败，请手动检查您的 Shell RC 文件。"; }

    echo ""
    echo "🗑️ Claude Code 配置清理完成。请重新启动终端以确保所有更改生效。"
    echo ""
}

# --- 主脚本逻辑 ---

main_menu() {
    echo "--- Claude Code 配置工具 ---"
    echo "请选择一个操作:"
    echo "1. 安装和配置 Claude Code"
    echo "2. 清理 Claude Code 配置"
    echo "3. 退出"
    echo ""
    read -p "请输入您的选择 (1-3): " main_choice

    case "$main_choice" in
        1)
            perform_install_and_configure
            ;;
        2)
            clear_configuration
            ;;
        3)
            echo "👋 退出脚本。感谢使用！"
            exit 0
            ;;
        *)
            echo "无效的选择 '$main_choice'。请选择 1, 2 或 3。"
            main_menu # Loop back to menu until valid input
            ;;
    esac
}

# Call the main menu to start the script interaction
main_menu

exit 0
