import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/nullability_suffix.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:isar/isar.dart';
import 'package:isar_generator/src/helper.dart';
import 'package:isar_generator/src/object_info.dart';
import 'package:dartx/dartx.dart';

class IsarAnalyzer {
  ObjectInfo analyze(Element element) {
    if (element is! ClassElement) {
      err('Only classes may be annotated with @Collection.', element);
    }

    final modelClass = element as ClassElement;
    final collectionAnn = getCollectionAnn(element)!;

    if (modelClass.isAbstract) {
      err('Class must not be abstract.', element);
    }

    if (!modelClass.isPublic) {
      err('Class must be public.', element);
    }

    final constructor =
        modelClass.constructors.firstOrNullWhere((c) => c.periodOffset == null);

    if (constructor == null) {
      err('Class needs an unnamed constructor.');
    }

    final isarName = getNameAnn(modelClass)?.name ?? modelClass.displayName;
    _checkName(isarName, element);

    final properties = <ObjectProperty>[];
    final links = <ObjectLink>[];
    final converterImports = <String>{};
    final allAccessors = {
      ...modelClass.accessors.mapNotNull((e) => e.variable),
      if (collectionAnn.inheritance)
        for (var supertype in modelClass.allSupertypes) ...[
          if (!supertype.isDartCoreObject)
            ...supertype.accessors.mapNotNull((e) => e.variable)
        ]
    };
    for (var propertyElement in allAccessors) {
      if (hasIgnoreAnn(propertyElement)) {
        continue;
      }

      final converter = findTypeConverter(propertyElement);
      if (converter != null) {
        converterImports.add(converter.location!.components[0]);
      }

      if (propertyElement.type.element!.name == 'IsarLink' ||
          propertyElement.type.element!.name == 'IsarLinks') {
        final link = analyzeObjectLink(propertyElement, converter);
        if (link == null) continue;
        links.add(link);
      } else {
        final property = analyzeObjectProperty(
          propertyElement,
          converter,
          constructor!,
        );
        if (property == null) continue;
        properties.add(property);
      }
    }

    final indexes = <ObjectIndex>[];
    for (var propertyElement in modelClass.fields) {
      if (links.any((it) => it.dartName == propertyElement.name)) continue;
      indexes.addAll(analyzeObjectIndex(properties, propertyElement));
    }
    if (indexes.map((e) => e.name).distinct().length != indexes.length) {
      err('Two or more indexes have the same name.', element);
    }

    var oidProperty = properties.firstOrNullWhere((it) => it.isId);
    if (oidProperty == null) {
      for (var i = 0; i < properties.length; i++) {
        final property = properties[i];
        if (property.isarName == 'id' &&
            property.converter == null &&
            property.isarType == IsarType.Long) {
          oidProperty = properties[i].copyWith(isId: true);
          properties[i] = oidProperty;
          break;
        }
      }
      if (oidProperty == null) {
        err('More than one property annotated with @Id().', element);
      }
    }

    if (oidProperty == null) {
      err('No property annotated with @Id().', element);
    }

    final sortedProperties = properties.sortedBy((p) {
      if (p.isId) {
        return -1; // Sort first
      }
      final index =
          constructor!.parameters.indexWhere((e) => e.name == p.dartName);
      return index == -1 ? 999999 : index;
    });

    final unknownConstructorParameter = constructor!.parameters
        .firstOrNullWhere((p) =>
            p.isNotOptional && properties.none((e) => e.dartName == p.name));
    if (unknownConstructorParameter != null) {
      err('Constructor parameter does not match a property.',
          unknownConstructorParameter);
    }

    final modelInfo = ObjectInfo(
      dartName: modelClass.displayName,
      isarName: isarName,
      properties: sortedProperties,
      indexes: indexes,
      links: links,
      imports: converterImports.toList(),
    );

    return modelInfo;
  }

  ClassElement? findTypeConverter(PropertyInducingElement property) {
    final annotations = getTypeConverterAnns(property);
    annotations.addAll(getTypeConverterAnns(property.enclosingElement!));

    for (var annotation in annotations) {
      final cls = annotation.type!.element as ClassElement;
      final dartType = cls.supertype!.typeArguments[0];
      if (dartType == property.type) {
        return cls;
      }
    }

    return null;
  }

  ObjectProperty? analyzeObjectProperty(PropertyInducingElement property,
      ClassElement? converter, ConstructorElement constructor) {
    if (!property.isPublic || property.isStatic) {
      return null;
    }

    final nullable = property.type.nullabilitySuffix != NullabilitySuffix.none;
    var elementNullable = false;
    if (property.type is ParameterizedType) {
      final typeArguments = (property.type as ParameterizedType).typeArguments;
      if (typeArguments.isNotEmpty) {
        final listType = typeArguments[0];
        elementNullable = listType.nullabilitySuffix != NullabilitySuffix.none;
      }
    }

    final nameAnn = getNameAnn(property);
    if (nameAnn != null && nameAnn.name.isEmpty) {
      err('Empty property names are not allowed.', property);
    }
    var isarName = nameAnn?.name ?? property.displayName;
    _checkName(isarName, property);

    IsarType? isarType;
    if (converter == null) {
      final size32 = hasSize32Ann(property);
      isarType = getIsarType(property.type, size32, property);
    } else {
      final isarDartType = converter.supertype!.typeArguments[1];
      final size32 = hasSize32Ann(converter);
      isarType = getIsarType(isarDartType, size32, converter);
    }

    if (isarType == null) {
      return null;
    }

    final isId = hasIdAnn(property);
    if (isId) {
      if (converter != null) {
        err('Converters are not allowed for ids.', property);
      } else if (isarType != IsarType.Long) {
        err('Only int ids are allowed', property);
      }
    }

    var type = property.type.getDisplayString(withNullability: true);
    if (type.endsWith('*')) {
      type = type.removeSuffix('*') + '?';
    }

    final constructorParameter =
        constructor.parameters.firstOrNullWhere((p) => p.name == property.name);
    int? constructorPosition;
    late PropertyDeser deserialize;
    if (constructorParameter != null) {
      if (constructorParameter.type != property.type) {
        err('Constructor parameter type does not match property type',
            constructorParameter);
      }
      deserialize = constructorParameter.isNamed
          ? PropertyDeser.NamedParam
          : PropertyDeser.PositionalParam;
      constructorPosition =
          constructor.parameters.indexOf(constructorParameter);
    } else {
      deserialize =
          property.setter == null ? PropertyDeser.None : PropertyDeser.Assign;
    }
    return ObjectProperty(
      dartName: property.displayName,
      isarName: isarName,
      dartType: type,
      isarType: isarType,
      isId: isId,
      converter: converter?.name,
      nullable: nullable,
      elementNullable: elementNullable,
      deserialize: deserialize,
      constructorPosition: constructorPosition,
    );
  }

  IsarType? getIsarType(DartType type, bool size32, Element element) {
    if (type.isDartCoreBool) {
      return IsarType.Bool;
    } else if (type.isDartCoreInt) {
      if (size32) {
        return IsarType.Int;
      } else {
        return IsarType.Long;
      }
    } else if (type.isDartCoreDouble) {
      if (size32) {
        return IsarType.Float;
      } else {
        return IsarType.Double;
      }
    } else if (type.isDartCoreString) {
      return IsarType.String;
    } else if (type.isDartCoreList) {
      final parameterizedType = type as ParameterizedType;
      final typeArguments = parameterizedType.typeArguments;
      if (typeArguments.isNotEmpty) {
        final listType = typeArguments[0];
        if (listType.isDartCoreBool) {
          return IsarType.BoolList;
        } else if (listType.isDartCoreInt) {
          if (size32) {
            return IsarType.IntList;
          } else {
            return IsarType.LongList;
          }
        } else if (listType.isDartCoreDouble) {
          if (size32) {
            return IsarType.FloatList;
          } else {
            return IsarType.DoubleList;
          }
        } else if (listType.isDartCoreString) {
          return IsarType.StringList;
        } else if (isDateTime(listType.element!)) {
          return IsarType.DateTimeList;
        }
      }
    } else if (isDateTime(type.element!)) {
      return IsarType.DateTime;
    } else if (isUint8List(type.element!)) {
      return IsarType.Bytes;
    }
  }

  ObjectLink? analyzeObjectLink(
      PropertyInducingElement property, ClassElement? converter) {
    if (!property.isPublic || property.isStatic || hasIgnoreAnn(property)) {
      return null;
    }

    if (converter != null) {
      err('Converters are not supported for links.', property);
    }

    final isLinks = property.type.element!.name == 'IsarLinks';

    final type = property.type as ParameterizedType;
    if (type.typeArguments.length != 1) {
      err('Illegal type arguments for link.', property);
    }
    final linkType = type.typeArguments[0];
    if (linkType.nullabilitySuffix != NullabilitySuffix.none) {
      err('Links type must not be nullable.', property);
    }

    final nameAnn = getNameAnn(property);
    if (nameAnn != null && nameAnn.name.isEmpty) {
      err('Empty link names are not allowed.', property);
    }
    var isarName = nameAnn?.name ?? property.displayName;
    _checkName(isarName, property);

    final targetColNameAnn = getNameAnn(linkType.element!);

    final backlinkAnn = getBacklinkAnn(property);
    return ObjectLink(
      dartName: property.displayName,
      isarName: isarName,
      targetDartName: backlinkAnn?.to,
      targetCollectionDartName: linkType.element!.name!,
      targetCollectionIsarName:
          targetColNameAnn?.name ?? linkType.element!.name!,
      links: isLinks,
      backlink: backlinkAnn != null,
    );
  }

  Iterable<ObjectIndex> analyzeObjectIndex(
      List<ObjectProperty> properties, FieldElement element) sync* {
    final property =
        properties.firstOrNullWhere((it) => it.dartName == element.name);
    if (property == null) return;

    final indexAnns = getIndexAnns(element).toList();
    for (var index in indexAnns) {
      if (!index.unique && index.replace) {
        err('Only unique indexes may replace existing entries', element);
      }

      final indexProperties = <ObjectIndexProperty>[];

      indexProperties.add(ObjectIndexProperty(
        property: property,
        type: index.type ??
            (property.isarType.isDynamic ? IndexType.hash : IndexType.value),
        caseSensitive: index.caseSensitive ?? property.isarType.containsString,
      ));
      for (var c in index.composite) {
        final compositeProperty =
            properties.firstOrNullWhere((it) => it.dartName == c.property);
        if (compositeProperty == null) {
          err('Property does not exist: "${c.property}".', element);
        } else {
          indexProperties.add(ObjectIndexProperty(
            property: compositeProperty,
            type: c.type ??
                (compositeProperty.isarType.isDynamic
                    ? IndexType.hash
                    : IndexType.value),
            caseSensitive:
                c.caseSensitive ?? compositeProperty.isarType.containsString,
          ));
        }
      }

      if (indexProperties.map((it) => it.property.isarName).distinct().length !=
          indexProperties.length) {
        err('Composite index contains duplicate properties.', element);
      }

      for (var i = 0; i < indexProperties.length; i++) {
        final indexProperty = indexProperties[i];
        if (indexProperty.property.isarType.isList &&
            indexProperty.type != IndexType.hash &&
            indexProperties.length > 1) {
          err('Composite indexes do not support non-hashed lists.', element);
        }
        if (property.isarType == IsarType.String) {
          if (indexProperty.type != IndexType.hash &&
              i != indexProperties.lastIndex) {
            err('Only the last property of a composite index may be a non-hashed String.',
                element);
          }
        }
        if (!indexProperty.property.isarType.isDynamic &&
            indexProperty.type != IndexType.value) {
          err('Only Strings and Lists may be hashed.', element);
        }
        if (indexProperty.property.isarType != IsarType.StringList &&
            indexProperty.type == IndexType.hashElements) {
          err('Only String lists may have hashed elements.', element);
        }
        if (indexProperty.property.isarType == IsarType.Bytes &&
            indexProperty.type != IndexType.hash) {
          err('Bytes indexes need to be hashed.', element);
        }
      }

      final name = index.name ??
          indexProperties.map((e) => e.property.isarName).join('_');
      _checkName(name, element);

      yield ObjectIndex(
        name: name,
        properties: indexProperties,
        unique: index.unique,
        replace: index.replace,
      );
    }
  }

  void _checkName(String name, Element element) {
    if (name.isBlank || name.startsWith('_')) {
      err('Names must not be blank or start with "_".', element);
    }
  }
}