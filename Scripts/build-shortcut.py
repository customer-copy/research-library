#!/usr/bin/env python3
"""Generate a platform-specific capture shortcut; sign with `shortcuts sign`."""
import argparse
import pathlib
import plistlib
import uuid

ROOT = pathlib.Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--platform", choices=("macos", "ios"), default="macos")
platform = parser.parse_args().platform
bundle = "org.researchlibrary.capture" if platform == "ios" else "org.researchlibrary.mac"
name = "Save to Research Library (iOS)" if platform == "ios" else "Save to Research Library"
def identifier():
    return str(uuid.uuid4()).upper()

def token(value):
    return {"Value": value, "WFSerializationType": "WFTextTokenAttachment"}

def variable(name):
    return token({"Type": "Variable", "VariableName": name})

def output(action_id, name):
    return token({"Type": "ActionOutput", "OutputUUID": action_id, "OutputName": name})

def input_value(value):
    return {"Type": "Variable", "Variable": value}

actions = []
def action(name, **parameters):
    action_id = identifier()
    parameters["UUID"] = action_id
    actions.append({"WFWorkflowActionIdentifier": name,
                    "WFWorkflowActionParameters": parameters})
    return action_id

def capture(parameter, value):
    action(f"{bundle}.AddToResearchLibraryIntent",
           AppIntentDescriptor={"AppIntentIdentifier": "AddToResearchLibraryIntent",
                                "BundleIdentifier": bundle,
                                "Name": "Research Library"},
           **{parameter: value})

repeat_group, type_group, url_group = identifier(), identifier(), identifier()
shortcut_input = token({"Type": "ExtensionInput"})
repeat_item = variable("Repeat Item")
input_group = identifier()
action("is.workflow.actions.conditional", WFInput=input_value(shortcut_input), WFCondition=100,
       GroupingIdentifier=input_group, WFControlFlowMode=0)
action("is.workflow.actions.conditional", GroupingIdentifier=input_group, WFControlFlowMode=1)
action("is.workflow.actions.alert", WFAlertActionTitle="Nothing to save",
       WFAlertActionMessage="Share a PDF or article URL, or copy a link before running this shortcut.",
       WFAlertActionCancelButtonShown=False)
action("is.workflow.actions.exit")
action("is.workflow.actions.conditional", GroupingIdentifier=input_group, WFControlFlowMode=2)
action("is.workflow.actions.repeat.each", WFInput=input_value(shortcut_input),
       GroupingIdentifier=repeat_group, WFControlFlowMode=0)
type_id = action("is.workflow.actions.getitemtype", WFInput=input_value(repeat_item))
action("is.workflow.actions.conditional", WFInput=input_value(output(type_id, "Type")),
       WFCondition=4, WFConditionalActionString="PDF",
       GroupingIdentifier=type_group, WFControlFlowMode=0)
capture("file", repeat_item)
action("is.workflow.actions.conditional", GroupingIdentifier=type_group, WFControlFlowMode=1)
url_id = action("is.workflow.actions.detect.link", WFInput=input_value(repeat_item))
urls = output(url_id, "URLs")
action("is.workflow.actions.conditional", WFInput=input_value(urls), WFCondition=100,
       GroupingIdentifier=url_group, WFControlFlowMode=0)
capture("url", urls)
action("is.workflow.actions.conditional", GroupingIdentifier=url_group, WFControlFlowMode=1)
action("is.workflow.actions.alert", WFAlertActionTitle="No article link or PDF",
       WFAlertActionMessage="Share a PDF or an article URL, or copy a link before running this shortcut.",
       WFAlertActionCancelButtonShown=False)
action("is.workflow.actions.exit")
action("is.workflow.actions.conditional", GroupingIdentifier=url_group, WFControlFlowMode=2)
action("is.workflow.actions.conditional", GroupingIdentifier=type_group, WFControlFlowMode=2)
action("is.workflow.actions.repeat.each", GroupingIdentifier=repeat_group, WFControlFlowMode=2)
action("is.workflow.actions.notification", WFNotificationActionTitle="Research Library",
       WFNotificationActionBody="Saved to the Inbox. Research Library on your Mac will organize it.")
workflow = {
    "WFWorkflowName": name,
    "WFWorkflowActions": actions,
    "WFWorkflowClientVersion": "2106.0.3",
    "WFWorkflowMinimumClientVersion": 900,
    "WFWorkflowMinimumClientVersionString": "900",
    "WFWorkflowHasShortcutInputVariables": True,
    "WFWorkflowHasOutputFallback": False,
    "WFWorkflowInputContentItemClasses": ["WFPDFContentItem", "WFURLContentItem",
                                          "WFSafariWebPageContentItem", "WFStringContentItem"],
    "WFWorkflowOutputContentItemClasses": [],
    "WFWorkflowTypes": ["ActionExtension", "NCWidget"] if platform == "ios" else ["ActionExtension", "NCWidget", "MenuBar"],
    "WFQuickActionSurfaces": [] if platform == "ios" else ["Finder", "ServicesMenu"],
    "WFWorkflowNoInputBehavior": {"Name": "GetClipboard"},
    "WFWorkflowImportQuestions": [],
    "WFWorkflowIcon": {"WFWorkflowIconGlyphNumber": 61456,
                       "WFWorkflowIconStartColor": 4274264319},
}
destination = ROOT / "Shortcuts" / f"{name}.unsigned.shortcut"
destination.parent.mkdir(exist_ok=True)
destination.write_bytes(plistlib.dumps(workflow, fmt=plistlib.FMT_BINARY))
print(destination)
