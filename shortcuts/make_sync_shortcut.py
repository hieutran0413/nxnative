#!/usr/bin/env python3
# Builds the "Dong bo save v2" Shortcut (iCloud <-> device save sync) as a signed .shortcut next to this script, and prints how to import it.
# Every folder is "Ask Each Time" (WFFolder Type Ask): a generated file cannot hold the folder bookmarks only the Shortcuts app creates. Each branch tells which folder to pick first;
# to make the Shortcut remember a folder, tap that action's folder field in the Shortcuts app once and choose it. To add a game, add it to GAMES and run this script again.
# Usage: python3 make_sync_shortcut.py [out.shortcut]   (signing needs `shortcuts sign`, macOS 12+, signed in to iCloud)
import plistlib, subprocess, sys, tempfile, uuid
from pathlib import Path

# name shown in the menu, iCloud folder under Game Saves (its `save` folder is synced; see AGENTS.md), device app folder in Files (On My iPhone / iPad > app folder > save)
GAMES = [("Animal Crossing", "Game Saves/Animal Crossing", "Animal Crossing: New Horizons"),
         ("Tears of the Kingdom", "Game Saves/Tears of the Kingdom", "The Legend of Zelda: Tears of the Kingdom")]
ASK = {"Value": {"Type": "Ask"}, "WFSerializationType": "WFTextTokenAttachment"}
U = lambda: str(uuid.uuid4()).upper()
def act(ident, **p): return {"WFWorkflowActionIdentifier": ident, "WFWorkflowActionParameters": p}
def text(s): return {"Value": {"string": s, "attachmentsByRange": {}}, "WFSerializationType": "WFTextTokenString"}
def ref(uid, name): return {"Value": {"OutputUUID": uid, "OutputName": name, "Type": "ActionOutput"}, "WFSerializationType": "WFTextTokenAttachment"}
def note(parts):
    s, att = "", {}
    for x in parts:
        if isinstance(x, str): s += x
        else: att["{%d, 1}" % len(s)] = {"OutputUUID": x[0], "OutputName": x[1], "Type": "ActionOutput"}; s += "￼"
    return {"Value": {"string": s, "attachmentsByRange": att}, "WFSerializationType": "WFTextTokenString"}
def menu(prompt, items, branches):
    gid = U()
    out = [act("is.workflow.actions.choosefrommenu", GroupingIdentifier=gid, WFControlFlowMode=0, WFMenuItems=items, WFMenuPrompt=prompt)]
    for title, body in zip(items, branches):
        out += [act("is.workflow.actions.choosefrommenu", GroupingIdentifier=gid, WFControlFlowMode=1, WFMenuItemTitle=title)] + body
    return out + [act("is.workflow.actions.choosefrommenu", GroupingIdentifier=gid, WFControlFlowMode=2)]
def copy(src_hint, dst_hint, done):   # pick the source folder, pick the destination folder, copy its items (folders inside it stay folders: Recursive off), count them
    g, c = U(), U()
    return [act("is.workflow.actions.alert", WFAlertActionTitle="Bước 1: chọn thư mục NGUỒN", WFAlertActionMessage=src_hint, WFAlertActionCancelButtonShown=True),
            act("is.workflow.actions.file.getfoldercontents", UUID=g, WFFolder=ASK, Recursive=False),
            act("is.workflow.actions.count", UUID=c, WFCountType="Items", WFInput=ref(g, "Contents of Folder")),
            act("is.workflow.actions.alert", WFAlertActionTitle="Bước 2: chọn thư mục ĐÍCH (sẽ bị ghi đè)", WFAlertActionMessage=dst_hint, WFAlertActionCancelButtonShown=True),
            act("is.workflow.actions.documentpicker.save", WFInput=ref(g, "Contents of Folder"), WFFolder=ASK, WFAskWhereToSave=False, WFSaveFileOverwrite=True),
            act("is.workflow.actions.notification", WFNotificationActionTitle="Đồng bộ save", WFNotificationActionBody=note([done + ": ", (c, "Count"), " mục"]))]
def game_branch(name, icloud, device):
    dev = f"Files › On My iPhone/iPad › {device} › save"; cloud = f"Files › iCloud Drive › {icloud.replace('/', ' › ')} › save"; bak = f"Files › iCloud Drive › Game Saves › Backups › {name}"
    return menu(f"{name}: chọn thao tác", ["📥 iCloud ➔ máy này", "📤 Máy này ➔ iCloud", "🛟 Sao lưu save của máy này"],
                [copy(cloud, dev, "Đã tải save từ iCloud"), copy(dev, cloud, "Đã đẩy save lên iCloud"), copy(dev, bak, "Đã sao lưu save")])
def build():
    acts = [act("is.workflow.actions.alert", WFAlertActionTitle="Đóng game trước khi đồng bộ", WFAlertActionMessage="Thoát hẳn game (vuốt lên khỏi đa nhiệm) rồi bấm OK, để tránh ghi đè save đang mở.", WFAlertActionCancelButtonShown=True)]
    acts += menu("Đồng bộ save game", [g[0] for g in GAMES], [game_branch(*g) for g in GAMES])
    return {"WFWorkflowActions": acts, "WFWorkflowClientVersion": "2700", "WFWorkflowMinimumClientVersion": 900, "WFWorkflowMinimumClientVersionString": "900",
            "WFWorkflowHasShortcutInputVariables": False, "WFWorkflowIcon": {"WFWorkflowIconStartColor": 4282601983, "WFWorkflowIconGlyphNumber": 59494},
            "WFWorkflowImportQuestions": [], "WFWorkflowInputContentItemClasses": [], "WFWorkflowTypes": []}
if __name__ == "__main__":
    out = Path(sys.argv[1] if len(sys.argv) > 1 else Path(__file__).with_name("Dong bo save v2.shortcut"))
    with tempfile.TemporaryDirectory() as t:
        raw = Path(t) / "unsigned.shortcut"; raw.write_bytes(plistlib.dumps(build(), fmt=plistlib.FMT_BINARY))
        signed = Path(t) / "signed.shortcut"   # `shortcuts sign` cannot write to every folder (external volumes), so it signs in the temp folder and the result is copied
        subprocess.run(["shortcuts", "sign", "--mode", "people-who-know-me", "--input", str(raw), "--output", str(signed)], check=True)
        out.write_bytes(signed.read_bytes())
    print(f"{out}: open it, confirm Add Shortcut")
