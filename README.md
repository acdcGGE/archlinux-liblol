# 适用于 Arch Linux 的 liblol

## 简介

本项目是liblol的Arch Linux适配版本。

libLoL（LoongArch on LoongArch）是一个旧世界 ABI 兼容性运行时库，用于在基于新世界的 Linux 发行版上运行为龙芯旧世界 ABI 编译的应用程序，例如 Loongson Loongnix、统信 UOS 、银河麒麟等平台上的应用（包括腾讯 QQ for Linux、金山 WPS for Linux等等）。

## 鸣谢

本项目的原始代码和开发思路来源于https://github.com/AOSC-Dev/liblol ，感谢 AOSC OS 开发者们的优秀工作。

## 环境说明

| 项目 | 值 |
|------|-----|
| 目标系统 | Arch Linux |
| glibc 版本 | 2.44 |
| 架构 | LoongArch (loongarch64) |

## 安装

sudo pacman -U <包>

## 组件说明

libLoL由两部分组成：

- **内核模块**：`la_ow_syscall` 模块提供旧世界系统调用支持，使旧世界应用程序能够在新的上游内核上运行。
- **用户空间**：经过补丁修改的 glibc 为旧世界应用程序提供符号支持。

## 许可证

本项目基于 GPL-2.0 协议开源。
