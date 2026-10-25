package bo.edu.uagrm.saludu.agenda.application;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.node.JsonNodeFactory;
import com.fasterxml.jackson.databind.node.ObjectNode;
import java.util.List;

/** Normalization characterized from the legacy finalize route, performed only on the server. */
public final class ClinicalHistoryData {
    private static final JsonNodeFactory J = JsonNodeFactory.instance;
    private ClinicalHistoryData() {}
    public static ObjectNode review(JsonNode value) {
        value=ClinicalJson.legacy(value);
        ObjectNode result=J.objectNode().put("schemaVersion",1);
        result.set("sex",text(value.path("sex"),40));
        result.set("personalHistory",texts(value.path("personalHistory"),4000,"pathological","surgical","allergic","regularMedications","familyRelevant"));
        ObjectNode habits=result.putObject("habits");
        habits.set("diet",choice(value.path("habits").path("diet"),"ADEQUATE","REGULAR","INADEQUATE"));
        for(String key:List.of("physicalActivity","tobacco","alcohol")) habits.set(key,choice(value.path("habits").path(key),"YES","NO"));
        ObjectNode vitals=result.putObject("vitals");
        for(String key:List.of("bloodPressureSystolic","bloodPressureDiastolic","heartRate","respiratoryRate","temperature","oxygenSaturation","weight","height")) vitals.set(key,number(value.path("vitals").path(key)));
        result.set("physicalExam",texts(value.path("physicalExam"),4000,"generalState","cardiopulmonary","abdomen","otherFindings"));
        ObjectNode lab=texts(value.path("laboratory"),4000,"hemogram","other");
        lab.set("bloodGroup",text(value.path("laboratory").path("bloodGroup"),100));
        for(String key:List.of("vdrl","chagas","coproparasitological")) lab.set(key,text(value.path("laboratory").path(key),1000));
        result.set("laboratory",lab);
        result.set("conduct",booleans(value.path("conduct"),"healthEducation","treatment","complementaryStudies","referral","medicalFollowUp","noObservations"));
        result.set("observations",text(value.path("observations"),8000));return ClinicalJson.spanish(result);
    }
    public static ObjectNode specialty(JsonNode value) {
        value=ClinicalJson.legacy(value);
        ObjectNode result=J.objectNode().put("schemaVersion",1);
        JsonNode code=text(value.path("specialtyCode"),80);result.put("specialtyCode",code.isNull()?"":code.asText());
        result.set("personalHistory",texts(value.path("personalHistory"),4000,"pathological","surgical","allergic","family"));
        ObjectNode eye=texts(value.path("ophthalmology"),100,"visualAcuityRight","visualAcuityLeft");eye.set("currentIllness",text(value.path("ophthalmology").path("currentIllness"),8000));result.set("ophthalmology",eye);
        JsonNode source=value.path("gynecology");
        ObjectNode gyn=texts(source,8000,"symptoms","previousTreatments","breastExam","externalGenitalExam","speculumExam","vaginalExam","cervixExam");
        for(String key:List.of("stiDetails","papDetails","familyOther"))gyn.set(key,text(source.path(key),4000));
        for(String key:List.of("lastMenstrualPeriod","lastPap"))gyn.set(key,text(source.path(key),10));
        gyn.set("contraceptiveOther",text(source.path("contraceptiveOther"),500));
        for(String key:List.of("menarcheAge","cycleDays"))gyn.set(key,number(source.path(key)));
        gyn.set("onset",choice(source.path("onset"),"ACUTE","SUBACUTE","CHRONIC"));gyn.set("menstrualPattern",choice(source.path("menstrualPattern"),"REGULAR","IRREGULAR"));gyn.set("papResult",choice(source.path("papResult"),"NORMAL","ALTERED"));
        for(String key:List.of("dysmenorrhea","leucorrhea","previousSti"))gyn.set(key,choice(source.path(key),"YES","NO"));
        for(String key:List.of("familyGynecologicalCancer","familyBreastCancer","familyDiabetes"))gyn.put(key,source.path(key).isBoolean()&&source.path(key).booleanValue());
        var methods=gyn.putArray("contraceptiveMethods");var seen=new java.util.HashSet<String>();
        if(source.path("contraceptiveMethods").isArray())for(JsonNode item:source.path("contraceptiveMethods"))if(item.isTextual()&&List.of("NONE","ORAL","INJECTABLE","IUD","IMPLANT","CONDOM").contains(item.asText())&&seen.add(item.asText())&&methods.size()<8)methods.add(item.asText());
        result.set("gynecology",gyn);return ClinicalJson.spanish(result);
    }
    private static ObjectNode texts(JsonNode node,int limit,String... keys){ObjectNode result=J.objectNode();for(String key:keys)result.set(key,text(node.path(key),limit));return result;}
    private static ObjectNode booleans(JsonNode node,String... keys){ObjectNode result=J.objectNode();for(String key:keys)result.put(key,node.path(key).isBoolean()&&node.path(key).booleanValue());return result;}
    private static JsonNode text(JsonNode node,int limit){if(!node.isTextual()||node.asText().trim().isEmpty())return J.nullNode();String s=node.asText().trim();return J.textNode(s.substring(0,Math.min(s.length(),limit)));}
    private static JsonNode choice(JsonNode node,String... allowed){return node.isTextual()&&List.of(allowed).contains(node.asText())?J.textNode(node.asText()):J.nullNode();}
    private static JsonNode number(JsonNode node){
        if(!node.isTextual()&&!node.isNumber())return J.nullNode();
        try {String value=node.asText().trim();double parsed=value.isEmpty()?0:Double.parseDouble(value);return Double.isFinite(parsed)&&parsed>=0&&parsed<=100000?J.numberNode(java.math.BigDecimal.valueOf(parsed).stripTrailingZeros()):J.nullNode();}
        catch(NumberFormatException ignored){return J.nullNode();}
    }
}
